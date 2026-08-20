import Foundation
import AppKit

enum UpdateState: Equatable {
    case upToDate(String)
    case available(installed: String, latest: String)
    case unknown(installed: String, reason: String)

    var isUpdate: Bool { if case .available = self { return true }; return false }
}

struct UpdateResult: Identifiable, Equatable {
    let id: String            // catalogue app id
    let name: String
    let state: UpdateState
    /// How the latest version was determined, shown so the user can judge it.
    let via: String
}

/// Works out which installed apps have a newer version available.
///
/// Four independent sources, tried in the order most likely to be authoritative
/// for that app. Anything it cannot establish confidently is reported as
/// unknown rather than guessed at.
@MainActor
final class UpdateChecker: ObservableObject {

    @Published private(set) var results: [UpdateResult] = []
    @Published private(set) var isChecking = false
    @Published private(set) var progress = 0.0
    @Published private(set) var lastChecked: Date?

    var updates: [UpdateResult] { results.filter { $0.state.isUpdate } }
    var unknowns: [UpdateResult] { results.filter { if case .unknown = $0.state { return true }; return false } }

    private var brewVersions: [String: String] = [:]

    /// Checking on launch is what makes this useful — an admin should not have
    /// to remember to look.
    var checkOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdatesOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdatesOnLaunch"); objectWillChange.send() }
    }

    var notifyOnUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnUpdates"); objectWillChange.send() }
    }

    /// Runs the check quietly in the background and notifies only when there is
    /// something to say.
    func checkInBackground(apps: [CatalogApp]) async {
        guard checkOnLaunch, !isChecking else { return }
        await check(apps: apps)
        guard notifyOnUpdates, !updates.isEmpty else { return }
        let n = updates.count
        let names = updates.prefix(3).map(\.name).joined(separator: ", ")
        let more = n > 3 ? " and \(n - 3) more" : ""
        Notifier.post(title: n == 1 ? "1 update available" : "\(n) updates available",
                      body: "\(names)\(more). Open Updates to install.",
                      id: "macsetup.updates")
    }

    func check(apps: [CatalogApp]) async {
        guard !isChecking else { return }
        isChecking = true
        progress = 0
        results = []
        defer { isChecking = false; lastChecked = Date() }

        // Only installed apps are worth checking.
        let installed: [(CatalogApp, String, URL)] = apps.compactMap { app in
            guard let bundle = app.bundleId,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
                  let version = Self.installedVersion(at: url) else { return nil }
            return (app, version, url)
        }
        guard !installed.isEmpty else { return }

        // One brew call for every brew-backed app, rather than one per app.
        await loadBrewVersions(for: installed.map(\.0))

        // Each app costs a network round trip or two, so run them in batches
        // rather than serially — 17 apps at 15s each would be unusable.
        var out: [UpdateResult] = []
        let total = Double(installed.count)
        let batchSize = 6
        for start in stride(from: 0, to: installed.count, by: batchSize) {
            let batch = Array(installed[start..<min(start + batchSize, installed.count)])
            let batchResults = await withTaskGroup(of: UpdateResult.self) { group -> [UpdateResult] in
                for (app, version, url) in batch {
                    group.addTask { @MainActor in
                        await self.evaluate(app: app, installed: version, at: url)
                    }
                }
                var acc: [UpdateResult] = []
                for await r in group { acc.append(r) }
                return acc
            }
            out.append(contentsOf: batchResults)
            progress = Double(out.count) / total
            results = out.sorted { lhs, rhs in
                if lhs.state.isUpdate != rhs.state.isUpdate { return lhs.state.isUpdate }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    // MARK: - Per-app resolution

    private func evaluate(app: CatalogApp, installed: String, at url: URL) async -> UpdateResult {
        var latest: String?
        var via = ""

        switch app.source.kind {
        case .brew:
            if let token = app.source.cask ?? app.source.formula, let v = brewVersions[token] {
                latest = v; via = "Homebrew"
            }
        case .github:
            if let repo = app.source.repo, let tag = await Self.githubLatestTag(repo) {
                latest = tag; via = "GitHub release"
            }
        case .direct:
            if let u = app.source.resolvedURL(arch: .current),
               let final = await Self.finalURL(u),
               let v = Self.versionFromURL(final) {
                latest = v; via = "vendor download"
            }
        case .script:
            break
        }

        // Sparkle is often the most accurate source, and needs no catalogue data.
        if latest == nil, let feed = Self.sparkleFeed(at: url),
           let v = await Self.sparkleLatest(feed) {
            latest = v; via = "Sparkle feed"
        }

        guard let latest else {
            let why = app.selfUpdates.map { "updates itself via \($0)" }
                ?? "vendor publishes no version"
            return UpdateResult(id: app.id, name: app.name,
                                state: .unknown(installed: installed, reason: why),
                                via: app.selfUpdates == nil ? "—" : "self-updating")
        }

        switch VersionCompare.compare(installed: installed, latest: latest) {
        case .newer:
            return UpdateResult(id: app.id, name: app.name,
                                state: .available(installed: installed, latest: latest), via: via)
        case .same, .older:
            return UpdateResult(id: app.id, name: app.name, state: .upToDate(installed), via: via)
        case .incomparable:
            let why = app.selfUpdates.map { "updates itself via \($0)" }
                ?? "cannot compare \(installed) with \(latest)"
            return UpdateResult(id: app.id, name: app.name,
                                state: .unknown(installed: installed, reason: why), via: via)
        }
    }

    // MARK: - Sources

    static func installedVersion(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return (d["CFBundleShortVersionString"] as? String)
            ?? (d["CFBundleVersion"] as? String)
    }

    static func sparkleFeed(at url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return d["SUFeedURL"] as? String
    }

    private static func sparkleLatest(_ feed: String) async -> String? {
        guard let url = URL(string: feed) else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        // Newest item first in almost every appcast.
        for pattern in [#"sparkle:shortVersionString="([^"]+)""#,
                        #"<sparkle:shortVersionString>([^<]+)<"#,
                        #"sparkle:version="([^"]+)""#] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let r = Range(m.range(at: 1), in: xml) {
                return String(xml[r])
            }
        }
        return nil
    }

    /// `/releases/latest` redirects to `/releases/tag/<tag>`, which needs no API
    /// call and is not subject to the 60-per-hour unauthenticated rate limit.
    /// The JSON API is kept only as a fallback.
    private static func githubLatestTag(_ repo: String) async -> String? {
        if let url = URL(string: "https://github.com/\(repo)/releases/latest") {
            var req = URLRequest(url: url)
            req.httpMethod = "HEAD"
            req.timeoutInterval = 10
            req.setValue("MacSetup/1.0", forHTTPHeaderField: "User-Agent")
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse,
               let final = http.url,
               final.path.contains("/releases/tag/") {
                let tag = final.lastPathComponent
                if !tag.isEmpty, tag != "latest" { return tag }
            }
        }
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: api); req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacSetup/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["tag_name"] as? String) ?? (obj["name"] as? String)
    }

    /// Follows redirects to whatever the vendor actually serves.
    private static func finalURL(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        // A one-byte ranged GET rather than HEAD: several CDNs answer HEAD with
        // an error or stop short of the final redirect.
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.timeoutInterval = 10
        req.setValue("MacSetup/1.0", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        return http.url
    }

    /// Vendors put the version in the filename (`Rectangle0.98.dmg`) or in a
    /// path segment (`/releases/3.6.4-28955b81/GitHubDesktop-arm64.zip`).
    /// Only whole segments that look like a version are trusted — scanning the
    /// entire URL would happily pull digits out of a CDN hash.
    static func versionFromURL(_ url: URL) -> String? {
        let name = url.lastPathComponent
        if let v = VersionCompare.extract(from: name), v.contains(".") { return v }
        let strict = #"^v?\d+(\.\d+){1,4}([-.][A-Za-z0-9]+)?$"#
        for segment in url.pathComponents.reversed() {
            guard segment.range(of: strict, options: .regularExpression) != nil else { continue }
            if let v = VersionCompare.extract(from: segment) { return v }
        }
        return nil
    }

    private func loadBrewVersions(for apps: [CatalogApp]) async {
        let casks = apps.compactMap { $0.source.kind == .brew ? $0.source.cask : nil }
        let formulae = apps.compactMap { $0.source.kind == .brew ? $0.source.formula : nil }
        guard !casks.isEmpty || !formulae.isEmpty else { return }
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

        brewVersions = await Task.detached(priority: .utility) { () -> [String: String] in
            var out: [String: String] = [:]
            func run(_ args: [String]) -> Data? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return nil }
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return d
            }
            if !casks.isEmpty, let d = run(["info", "--json=v2", "--cask"] + casks),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = obj["casks"] as? [[String: Any]] {
                for c in list {
                    if let token = c["token"] as? String, let v = c["version"] as? String {
                        out[token] = v.components(separatedBy: ",").first ?? v
                    }
                }
            }
            if !formulae.isEmpty, let d = run(["info", "--json=v2", "--formula"] + formulae),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let list = obj["formulae"] as? [[String: Any]] {
                for f in list {
                    if let name = f["name"] as? String,
                       let versions = f["versions"] as? [String: Any],
                       let v = versions["stable"] as? String {
                        out[name] = v
                    }
                }
            }
            return out
        }.value
    }
}
