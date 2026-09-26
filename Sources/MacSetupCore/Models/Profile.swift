import Foundation

/// A saved selection of apps and tweaks, re-applicable on the next Mac.
public struct Profile: Codable, Identifiable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    public var notes: String = ""
    public var appIDs: [String]
    public var tweakIDs: [String]
    public var webAppIDs: [String] = []
    /// Custom web apps travel inside the profile so an imported one still works
    /// on a machine that has never seen it.
    public var customWebApps: [WebApp] = []
    /// Run options travel with the profile, so a "Business Baseline" applied on
    /// another Mac behaves the same way rather than reverting to defaults.
    public var options: SavedOptions? = nil
    public var created: Date = Date()

    public struct SavedOptions: Codable, Hashable {
        public var verifySignatures: Bool
        public var strictVerify: Bool
        public var skipInstalled: Bool
        public var installToUserApplications: Bool
        public var standaloneWebApps: Bool

        public init(_ o: ScriptOptions) {
            verifySignatures = o.verifySignatures
            strictVerify = o.strictVerify
            skipInstalled = o.skipInstalled
            installToUserApplications = o.installToUserApplications
            standaloneWebApps = o.standaloneWebApps
        }

        public func apply(to o: inout ScriptOptions) {
            o.verifySignatures = verifySignatures
            o.strictVerify = strictVerify
            o.skipInstalled = skipInstalled
            o.installToUserApplications = installToUserApplications
            o.standaloneWebApps = standaloneWebApps
        }
    }

    // Decoded by hand so profiles saved before web apps existed still load.
    enum CodingKeys: String, CodingKey {
        case id, name, notes, appIDs, tweakIDs, webAppIDs, customWebApps, options, created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        appIDs = try c.decodeIfPresent([String].self, forKey: .appIDs) ?? []
        tweakIDs = try c.decodeIfPresent([String].self, forKey: .tweakIDs) ?? []
        webAppIDs = try c.decodeIfPresent([String].self, forKey: .webAppIDs) ?? []
        customWebApps = try c.decodeIfPresent([WebApp].self, forKey: .customWebApps) ?? []
        options = try c.decodeIfPresent(SavedOptions.self, forKey: .options)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    /// Exchange format written by "Export profile…" — deliberately plain so it
    /// can be committed to a repo or handed to a colleague.
    public struct Document: Codable {
        public let kind: String
        public let version: Int
        public let name: String
        public let notes: String
        public let apps: [String]
        public let tweaks: [String]
        public let webApps: [String]?
        public let customWebApps: [WebApp]?
        public let options: SavedOptions?
        public let exported: Date

        public init(kind: String, version: Int, name: String, notes: String, apps: [String],
                    tweaks: [String], webApps: [String]?, customWebApps: [WebApp]?,
                    options: SavedOptions?, exported: Date) {
            self.kind = kind
            self.version = version
            self.name = name
            self.notes = notes
            self.apps = apps
            self.tweaks = tweaks
            self.webApps = webApps
            self.customWebApps = customWebApps
            self.options = options
            self.exported = exported
        }
    }

    public var document: Document {
        Document(kind: "macsetup.profile", version: 3, name: name,
                 notes: notes, apps: appIDs, tweaks: tweakIDs,
                 webApps: webAppIDs, customWebApps: customWebApps,
                 options: options, exported: Date())
    }

    public init(name: String, notes: String = "", appIDs: [String], tweakIDs: [String],
                webAppIDs: [String] = [], customWebApps: [WebApp] = [],
                options: SavedOptions? = nil) {
        self.options = options
        self.name = name
        self.notes = notes
        self.appIDs = appIDs
        self.tweakIDs = tweakIDs
        self.webAppIDs = webAppIDs
        self.customWebApps = customWebApps
    }

    public init(document d: Document) {
        self.name = d.name
        self.notes = d.notes
        self.appIDs = d.apps
        self.tweakIDs = d.tweaks
        self.webAppIDs = d.webApps ?? []
        self.customWebApps = d.customWebApps ?? []
        self.options = d.options
    }
}

@MainActor
public final class ProfileStore: ObservableObject {
    @Published public private(set) var profiles: [Profile] = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSetup", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("profiles.json")
    }()

    public init() { load() }

    public func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else { return }
        profiles = decoded
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) { try? data.write(to: url, options: .atomic) }
    }

    public func save(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile }
        else { profiles.append(profile) }
        persist()
    }

    public func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    public func rename(_ profile: Profile, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i].name = name
        persist()
    }

    // MARK: Import / export

    public func export(_ profile: Profile, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(profile.document).write(to: url, options: .atomic)
    }

    @discardableResult
    public func importProfile(from url: URL) throws -> Profile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let doc = try dec.decode(Profile.Document.self, from: Data(contentsOf: url))
        guard doc.kind == "macsetup.profile" else { throw ProfileError.notAProfile }
        var p = Profile(document: doc)
        if profiles.contains(where: { $0.name == p.name }) { p.name += " (imported)" }
        save(p)
        return p
    }
}

public enum ProfileError: LocalizedError {
    case notAProfile
    public var errorDescription: String? { "That file is not a MacSetup profile." }
}
