import Foundation

// MARK: - Catalog schema

public struct Catalog: Codable {
    public let schemaVersion: Int
    public let updated: String
    public let categories: [AppCategory]
    public let apps: [CatalogApp]
    public let systemDefaults: [DefaultTweak]
    /// Optional so an older catalog.json still decodes.
    public let webApps: [WebApp]?
    /// Optional so an older catalog.json still decodes.
    public let roleTemplates: [RoleTemplate]?

    public var webAppList: [WebApp] { webApps ?? [] }
    public var roleTemplateList: [RoleTemplate] { roleTemplates ?? [] }

    public init(schemaVersion: Int, updated: String, categories: [AppCategory], apps: [CatalogApp],
                systemDefaults: [DefaultTweak], webApps: [WebApp]?, roleTemplates: [RoleTemplate]?) {
        self.schemaVersion = schemaVersion
        self.updated = updated
        self.categories = categories
        self.apps = apps
        self.systemDefaults = systemDefaults
        self.webApps = webApps
        self.roleTemplates = roleTemplates
    }
}

public struct AppCategory: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let symbol: String
    public let order: Int

    public init(id: String, name: String, symbol: String, order: Int) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.order = order
    }
}

public enum SourceKind: String, Codable {
    case direct     // vendor's own download URL
    case github     // resolved from a GitHub release
    case brew       // Homebrew cask or formula
    case script     // vendor's own install script
}

/// Where an app comes from and what shape the download is.
public struct AppSource: Codable, Hashable {
    public let kind: SourceKind
    public var url: String?
    public var urlArm64: String?
    public var urlX86: String?
    public var format: String?        // dmg | pkg | zip
    public var repo: String?          // owner/name for .github
    public var assetPattern: String?  // regex matched against release asset names
    public var cask: String?
    public var formula: String?
    public var verify: String?        // command that must exist on PATH afterwards
    public var env: [String: String]?

    public init(kind: SourceKind, url: String? = nil, urlArm64: String? = nil, urlX86: String? = nil,
                format: String? = nil, repo: String? = nil, assetPattern: String? = nil,
                cask: String? = nil, formula: String? = nil, verify: String? = nil,
                env: [String: String]? = nil) {
        self.kind = kind
        self.url = url
        self.urlArm64 = urlArm64
        self.urlX86 = urlX86
        self.format = format
        self.repo = repo
        self.assetPattern = assetPattern
        self.cask = cask
        self.formula = formula
        self.verify = verify
        self.env = env
    }

    /// The URL to fetch on this machine's architecture.
    public func resolvedURL(arch: Arch) -> String? {
        if let url { return url }
        return arch == .appleSilicon ? urlArm64 : urlX86
    }

    public var needsRoot: Bool { format == "pkg" }

    public var shortLabel: String {
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

public struct CatalogApp: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: String
    public let vendor: String
    public let summary: String
    public let homepage: String
    public let bundleId: String?
    public let teamId: String?
    public let tags: [String]
    public let license: String
    /// Explicit icon URL. Needed whenever a host favicon would be shared with
    /// another entry — every microsoft.com app would otherwise look identical.
    /// The literal "none" forces the generated monogram instead.
    public let icon: String?
    /// Set when the app ships its own updater, so the update check can say so
    /// instead of reporting an unhelpful "unknown".
    public let selfUpdates: String?
    /// True when Homebrew will shell out to sudo for this cask (its artifact is
    /// a .pkg). Those cannot prompt when the run is launched from the app.
    public let needsAdmin: Bool?
    /// True when the Homebrew cask runs its own installer program rather than
    /// shipping a .pkg. Those cannot be driven without a terminal; a .pkg can be
    /// fetched by Homebrew and installed through the elevated batch instead.
    public let caskInstaller: Bool?
    public let source: AppSource
    public let fallback: AppSource?

    public init(id: String, name: String, category: String, vendor: String, summary: String,
                homepage: String, bundleId: String?, teamId: String?, tags: [String],
                license: String, icon: String?, selfUpdates: String?, needsAdmin: Bool?,
                caskInstaller: Bool?, source: AppSource, fallback: AppSource?) {
        self.id = id
        self.name = name
        self.category = category
        self.vendor = vendor
        self.summary = summary
        self.homepage = homepage
        self.bundleId = bundleId
        self.teamId = teamId
        self.tags = tags
        self.license = license
        self.icon = icon
        self.selfUpdates = selfUpdates
        self.needsAdmin = needsAdmin
        self.caskInstaller = caskInstaller
        self.source = source
        self.fallback = fallback
    }

    /// Everything the search field matches against.
    public var searchHaystack: String {
        ([name, vendor, summary, id] + tags).joined(separator: " ").lowercased()
    }

    public var needsRoot: Bool {
        source.needsRoot || (needsAdmin ?? false) || (source.kind == .script && id == "homebrew")
    }

    /// A Homebrew cask that installs a .pkg needs a terminal for its sudo
    /// prompt, so it cannot be installed from inside the app.
    /// Only installer-script casks truly need a terminal.
    public var needsTerminal: Bool { (caskInstaller ?? false) && source.kind == .brew }

    /// A cask that ships a .pkg: fetch it with Homebrew, install it elevated.
    public var isBrewPackage: Bool {
        source.kind == .brew && (needsAdmin ?? false) && !(caskInstaller ?? false)
            && source.cask != nil
    }

    /// True for anything that would have to go through the script's single
    /// elevated batch (an admin-privileges prompt) or a real terminal to
    /// install unattended. The canonical definition — every caller that needs
    /// to decide "can this run with no one there to click a password dialog"
    /// checks this, rather than re-deriving the same three conditions.
    public var needsElevatedBatch: Bool { needsRoot || isBrewPackage || needsTerminal }
}

public struct DefaultTweak: Codable, Identifiable, Hashable {
    public let id: String
    public let group: String
    public let name: String
    public let detail: String
    public let command: String
    public let revert: String
    public let restart: [String]
    public let recommended: Bool

    public init(id: String, group: String, name: String, detail: String, command: String,
                revert: String, restart: [String], recommended: Bool) {
        self.id = id
        self.group = group
        self.name = name
        self.detail = detail
        self.command = command
        self.revert = revert
        self.restart = restart
        self.recommended = recommended
    }
}

/// One thing the uninstaller can remove. Built either from a catalogue entry
/// (so Homebrew and package handling are known) or from a bare bundle found on
/// disk, which can only be moved to the Trash.
public struct UninstallTarget: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let kind: String      // brew | pkg | app
    public let token: String     // Homebrew cask or formula, when kind == brew

    public init(_ app: CatalogApp) {
        id = app.id
        name = app.name
        bundleID = app.bundleId ?? ""
        if app.source.kind == .brew { kind = "brew" }
        else if app.source.format == "pkg" { kind = "pkg" }
        else { kind = "app" }
        token = app.source.cask ?? app.source.formula ?? ""
    }

    public init(bundleName: String, bundleID: String) {
        id = "bundle:\(bundleID.isEmpty ? bundleName : bundleID)"
        name = bundleName
        self.bundleID = bundleID
        kind = "app"
        token = ""
    }
}

/// An application found on this Mac.
public struct InstalledEntry: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let bundleID: String
    public let version: String
    public let path: String
    public let catalogID: String?

    public var inCatalogue: Bool { catalogID != nil }

    public init(id: String, name: String, bundleID: String, version: String,
                path: String, catalogID: String?) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.path = path
        self.catalogID = catalogID
    }
}

// MARK: - Architecture

public enum Arch: String, Codable {
    case appleSilicon = "arm64"
    case intel = "x86_64"

    public static var current: Arch {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.hasPrefix("arm") ? .appleSilicon : .intel
    }

    public var display: String { self == .appleSilicon ? "Apple Silicon" : "Intel" }
}

// MARK: - Loading

public enum CatalogLoader {
    /// Looks in the SPM resource bundle first, then the app bundle, then alongside the
    /// executable — so the same code works under `swift run` and inside MacSetup.app.
    public static func load() throws -> Catalog {
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

public enum CatalogError: LocalizedError {
    case notFound(searched: [String])
    public var errorDescription: String? {
        switch self {
        case .notFound(let searched):
            return "catalog.json could not be found. Looked in:\n" + searched.joined(separator: "\n")
        }
    }
}
