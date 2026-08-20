import Foundation

// MARK: - Catalog schema

struct Catalog: Codable {
    let schemaVersion: Int
    let updated: String
    let categories: [AppCategory]
    let apps: [CatalogApp]
    let systemDefaults: [DefaultTweak]
    /// Optional so an older catalog.json still decodes.
    let webApps: [WebApp]?

    var webAppList: [WebApp] { webApps ?? [] }
}

struct AppCategory: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let order: Int
}

enum SourceKind: String, Codable {
    case direct     // vendor's own download URL
    case github     // resolved from a GitHub release
    case brew       // Homebrew cask or formula
    case script     // vendor's own install script
}

/// Where an app comes from and what shape the download is.
struct AppSource: Codable, Hashable {
    let kind: SourceKind
    var url: String?
    var urlArm64: String?
    var urlX86: String?
    var format: String?        // dmg | pkg | zip
    var repo: String?          // owner/name for .github
    var assetPattern: String?  // regex matched against release asset names
    var cask: String?
    var formula: String?
    var verify: String?        // command that must exist on PATH afterwards
    var env: [String: String]?

    /// The URL to fetch on this machine's architecture.
    func resolvedURL(arch: Arch) -> String? {
        if let url { return url }
        return arch == .appleSilicon ? urlArm64 : urlX86
    }

    var needsRoot: Bool { format == "pkg" }

    var shortLabel: String {
        switch kind {
        case .direct: return "Direct from \(hostname ?? "vendor")"
        case .github: return "GitHub release · \(repo ?? "")"
        case .brew:   return "Homebrew · \(cask ?? formula ?? "")"
        case .script: return "Vendor install script"
        }
    }

    private var hostname: String? {
        guard let s = url ?? urlArm64 ?? urlX86, let h = URL(string: s)?.host else { return nil }
        return h
    }
}

struct CatalogApp: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let vendor: String
    let summary: String
    let homepage: String
    let bundleId: String?
    let teamId: String?
    let tags: [String]
    let license: String
    /// Explicit icon URL. Needed whenever a host favicon would be shared with
    /// another entry — every microsoft.com app would otherwise look identical.
    /// The literal "none" forces the generated monogram instead.
    let icon: String?
    /// Set when the app ships its own updater, so the update check can say so
    /// instead of reporting an unhelpful "unknown".
    let selfUpdates: String?
    /// True when Homebrew will shell out to sudo for this cask (its artifact is
    /// a .pkg). Those cannot prompt when the run is launched from the app.
    let needsAdmin: Bool?
    /// True when the Homebrew cask runs its own installer program rather than
    /// shipping a .pkg. Those cannot be driven without a terminal; a .pkg can be
    /// fetched by Homebrew and installed through the elevated batch instead.
    let caskInstaller: Bool?
    let source: AppSource
    let fallback: AppSource?

    /// Everything the search field matches against.
    var searchHaystack: String {
        ([name, vendor, summary, id] + tags).joined(separator: " ").lowercased()
    }

    var needsRoot: Bool {
        source.needsRoot || (needsAdmin ?? false) || (source.kind == .script && id == "homebrew")
    }

    /// A Homebrew cask that installs a .pkg needs a terminal for its sudo
    /// prompt, so it cannot be installed from inside the app.
    /// Only installer-script casks truly need a terminal.
    var needsTerminal: Bool { (caskInstaller ?? false) && source.kind == .brew }

    /// A cask that ships a .pkg: fetch it with Homebrew, install it elevated.
    var isBrewPackage: Bool {
        source.kind == .brew && (needsAdmin ?? false) && !(caskInstaller ?? false)
            && source.cask != nil
    }
}

struct DefaultTweak: Codable, Identifiable, Hashable {
    let id: String
    let group: String
    let name: String
    let detail: String
    let command: String
    let revert: String
    let restart: [String]
    let recommended: Bool
}

/// One thing the uninstaller can remove. Built either from a catalogue entry
/// (so Homebrew and package handling are known) or from a bare bundle found on
/// disk, which can only be moved to the Trash.
struct UninstallTarget: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let kind: String      // brew | pkg | app
    let token: String     // Homebrew cask or formula, when kind == brew

    init(_ app: CatalogApp) {
        id = app.id
        name = app.name
        bundleID = app.bundleId ?? ""
        if app.source.kind == .brew { kind = "brew" }
        else if app.source.format == "pkg" { kind = "pkg" }
        else { kind = "app" }
        token = app.source.cask ?? app.source.formula ?? ""
    }

    init(bundleName: String, bundleID: String) {
        id = "bundle:\(bundleID.isEmpty ? bundleName : bundleID)"
        name = bundleName
        self.bundleID = bundleID
        kind = "app"
        token = ""
    }
}

/// An application found on this Mac.
struct InstalledEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let version: String
    let path: String
    let catalogID: String?

    var inCatalogue: Bool { catalogID != nil }
}

// MARK: - Architecture

enum Arch: String {
    case appleSilicon = "arm64"
    case intel = "x86_64"

    static var current: Arch {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.hasPrefix("arm") ? .appleSilicon : .intel
    }

    var display: String { self == .appleSilicon ? "Apple Silicon" : "Intel" }
}

// MARK: - Loading

enum CatalogLoader {
    /// Looks in the SPM resource bundle first, then the app bundle, then alongside the
    /// executable — so the same code works under `swift run` and inside MacSetup.app.
    static func load() throws -> Catalog {
        // Deliberately does NOT touch Bundle.module. SwiftPM's generated accessor
        // calls fatalError when it cannot find its resource bundle, and it looks
        // only in the app bundle root and at an absolute path baked in at build
        // time. A distributed copy has neither, so merely referencing it crashes
        // the app on launch on any machine other than the one that built it.
        // The executable-relative paths below cover `swift run` just as well.
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "catalog", withExtension: "json") { candidates.append(u) }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("catalog.json"))
            candidates.append(res.appendingPathComponent("MacSetup_MacSetup.bundle/catalog.json"))
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("catalog.json"))
        candidates.append(exeDir.appendingPathComponent("MacSetup_MacSetup.bundle/catalog.json"))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Catalog.self, from: data)
        }
        throw CatalogError.notFound(searched: candidates.map(\.path))
    }
}

enum CatalogError: LocalizedError {
    case notFound(searched: [String])
    var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return "catalog.json could not be found. Looked in:\n" + searched.joined(separator: "\n")
        }
    }
}
