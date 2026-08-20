import AppKit
import SwiftUI

/// Supplies a small icon for every catalogue entry, cheapest source first:
///
///   1. the real icon, if the app is already installed on this Mac (offline, exact)
///   2. a previously fetched icon from the on-disk cache
///   3. the vendor's own site icon — first-party only, no third-party icon service
///   4. a generated monogram tile, so a card is never blank
enum IconSource: String {
    case installed, cache, explicit, site, monogram
}

/// Anything that can be shown with an icon. Keeps catalogue apps and web apps
/// on one code path, with separate cache keys so ids cannot collide.
struct IconTarget: Equatable {
    let key: String
    let name: String
    let bundleID: String?
    let explicitIcon: String?
    let host: String?
    /// Skip remote lookup entirely and draw a monogram.
    var forceMonogram: Bool = false

    init(_ app: CatalogApp) {
        key = "app-\(app.id)"
        name = app.name
        bundleID = app.bundleId
        host = URL(string: app.homepage)?.host
        if let explicit = app.icon {
            // "none" means every candidate would be a duplicate, so go straight
            // to a monogram, which is at least distinct per app.
            explicitIcon = explicit == "none" ? nil : explicit
            forceMonogram = explicit == "none"
        } else if let owner = Self.githubOwner(app) {
            // Every github.com project shares one favicon, so use the owner's
            // avatar instead.
            explicitIcon = "https://github.com/\(owner).png?size=128"
            forceMonogram = false
        } else {
            explicitIcon = nil
            forceMonogram = false
        }
    }

    /// Only when the project's home really is GitHub. An app with its own site
    /// has its own icon there, and the owner's avatar is often a personal
    /// photograph — which looks wrong as an application icon.
    private static func githubOwner(_ app: CatalogApp) -> String? {
        guard let u = URL(string: app.homepage), u.host == "github.com" else { return nil }
        return u.path.split(separator: "/").first.map(String.init)
    }

    init(_ web: WebApp) {
        key = "web-\(web.id)"
        name = web.name
        forceMonogram = (web.icon == "none")
        // A web app already installed by MacSetup carries this bundle id, so its
        // real icon is reused instead of being fetched again.
        bundleID = "local.macsetup.webapp.\(web.id)"
        explicitIcon = web.icon == "none" ? nil : web.icon
        host = URL(string: web.url)?.host
    }
}

@MainActor
final class IconProvider: ObservableObject {

    // Deliberately NOT @Published. Publishing on every icon load invalidated
    // every view observing this object, so each icon that arrived re-rendered
    // the whole grid — which is what made scrolling stutter. Views now hold
    // their own image in @State and ask for it once.
    private(set) var icons: [String: NSImage] = [:]
    /// Where each icon came from — surfaced by `--check-icons`.
    private(set) var sources: [String: IconSource] = [:]
    private var inFlight: Set<String> = []

    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSetup/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Vendor-site lookups are opt-out, for locked-down or offline networks.
    var allowRemote: Bool {
        get { UserDefaults.standard.object(forKey: "loadRemoteIcons") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "loadRemoteIcons")
            objectWillChange.send()
        }
    }

    func icon(_ target: IconTarget) -> NSImage? { icons[target.key] }

    /// Resolve once and hand back the image. Callers keep it in their own state,
    /// so a load never invalidates anything but the one view that asked.
    func image(for target: IconTarget) async -> NSImage? {
        if let cached = icons[target.key] { return cached }
        await load(target)
        return icons[target.key]
    }

    func load(_ target: IconTarget) async {
        guard icons[target.key] == nil, !inFlight.contains(target.key) else { return }
        inFlight.insert(target.key)
        defer { inFlight.remove(target.key) }

        // 1. installed locally
        if let bundle = target.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 64, height: 64)
            icons[target.key] = image
            sources[target.key] = .installed
            return
        }

        // 2. disk cache
        let cached = cacheDir.appendingPathComponent("\(target.key).png")
        if let image = NSImage(contentsOf: cached) {
            icons[target.key] = image
            sources[target.key] = .cache
            return
        }

        // 3. an explicit icon URL, then the site itself
        if allowRemote && !target.forceMonogram {
            var data: Data?
            var from = IconSource.site
            if let explicit = target.explicitIcon {
                let d = await Self.get(explicit)
                if let d, Self.isImage(d) { data = d; from = .explicit }
            }
            if data == nil, let host = target.host {
                data = await Self.fetchSiteIcon(host: host)
                from = .site
            }
            if let data, let image = NSImage(data: data), image.size.width > 1 {
                let scaled = Self.resize(image, to: 64)
                icons[target.key] = scaled
                sources[target.key] = from
                if let png = Self.png(scaled) { try? png.write(to: cached) }
                return
            }
        }

        // 4. monogram
        icons[target.key] = Self.monogram(name: target.name, seed: target.key)
        sources[target.key] = .monogram
    }

    // MARK: - Remote lookup

    private nonisolated static func fetchSiteIcon(host: String) async -> Data? {
        // Well-known paths first — one request each, no HTML parsing needed.
        let direct = ["https://\(host)/apple-touch-icon.png",
                      "https://\(host)/apple-touch-icon-precomposed.png",
                      "https://\(host)/favicon.ico"]
        for candidate in direct {
            // A site that serves an HTML soft-404 for a missing icon path would
            // otherwise poison the chain, so require real image bytes.
            if let d = await get(candidate), isImage(d) { return d }
        }
        // Otherwise read the homepage and follow whatever icon it declares.
        guard let html = await get("https://\(host)/"),
              let text = String(data: html.prefix(120_000), encoding: .utf8) else { return nil }
        let pattern = #"<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range, in: text) else { continue }
            let tag = String(text[r])
            guard let hrefRe = try? NSRegularExpression(pattern: #"href=["']([^"']+)["']"#, options: .caseInsensitive),
                  let hm = hrefRe.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let hr = Range(hm.range(at: 1), in: tag) else { continue }
            var href = String(tag[hr])
            if href.hasPrefix("//") { href = "https:" + href }
            else if href.hasPrefix("/") { href = "https://\(host)" + href }
            else if !href.hasPrefix("http") { href = "https://\(host)/" + href }
            if let d = await get(href), isImage(d) { return d }
        }
        return nil
    }

    /// True when the bytes actually decode as an image of usable size.
    nonisolated static func isImage(_ data: Data) -> Bool {
        guard data.count > 100, let image = NSImage(data: data) else { return false }
        return image.size.width >= 16 && image.size.height >= 16
    }

    private nonisolated static func get(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        req.setValue("MacSetup/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Drawing

    private static func resize(_ image: NSImage, to side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// Exposed so `--check-icons` can spot two entries resolving to the same art.
    static func fingerprint(_ image: NSImage) -> String {
        guard let data = png(image) else { return "?" }
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in data { hash ^= UInt64(byte); hash = hash &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A deterministic coloured tile with the app's initials.
    static func monogram(name: String, seed: String) -> NSImage {
        let side: CGFloat = 64
        let letters = initials(name)
        let hue = stableHue(seed)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor(calibratedHue: hue, saturation: 0.52, brightness: 0.80, alpha: 1).setFill()
        path.fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: letters.count > 1 ? 25 : 32, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let size = letters.size(withAttributes: attrs)
        letters.draw(in: NSRect(x: 0, y: (side - size.height) / 2, width: side, height: size.height),
                     withAttributes: attrs)

        image.unlockFocus()
        return image
    }

    private static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    /// FNV-1a, so a given app always gets the same colour across launches
    /// (Swift's own hashValue is seeded per process and would not).
    private static func stableHue(_ id: String) -> CGFloat {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return CGFloat(hash % 360) / 360.0
    }
}
