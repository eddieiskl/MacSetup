import Foundation

/// A finding's status, deterministic and never guessed: everything not
/// positively established is `.unknown`, never assumed compliant or missing.
public enum ComplianceStatus: String, Codable {
    case compliant
    case missing
    case outdated
    case different
    case unknown
    case extra
    case notApplicable
}

/// What was compared against — a saved profile or a bundled role template —
/// so a report is self-describing on its own, e.g. once exported as JSON.
public struct DesiredStateSource: Codable {
    public enum Kind: String, Codable { case profile, roleTemplate }
    public let kind: Kind
    public let name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

public struct AppFinding: Codable, Identifiable {
    public var id: String
    public let name: String
    public let status: ComplianceStatus
    public let installedVersion: String?
    public let latestVersion: String?
    public let detail: String

    public init(id: String, name: String, status: ComplianceStatus,
                installedVersion: String?, latestVersion: String?, detail: String) {
        self.id = id
        self.name = name
        self.status = status
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.detail = detail
    }
}

public struct TweakFinding: Codable, Identifiable {
    public var id: String
    public let name: String
    public let status: ComplianceStatus
    public let detail: String

    public init(id: String, name: String, status: ComplianceStatus, detail: String) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public struct WebAppFinding: Codable, Identifiable {
    public var id: String
    public let name: String
    public let status: ComplianceStatus
    public let detail: String

    public init(id: String, name: String, status: ComplianceStatus, detail: String) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// An app present on the Mac that the desired state didn't ask for.
/// Informational only — see `RemediationPlanner`, which never proposes
/// removing one of these unless the caller explicitly opts in.
public struct ExtraAppFinding: Codable, Identifiable {
    public var id: String { path }
    public let name: String
    public let bundleID: String
    public let path: String
    /// The catalogue id, when this app happens to be one MacSetup knows about.
    public let catalogID: String?
    public let detail: String

    public init(name: String, bundleID: String, path: String, catalogID: String?, detail: String) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
        self.catalogID = catalogID
        self.detail = detail
    }

    public var isCatalogued: Bool { catalogID != nil }
}

public struct DesiredStateReport: Codable {
    public struct Summary: Codable {
        public let compliant: Int
        public let missing: Int
        public let outdated: Int
        public let different: Int
        public let unknown: Int
        public let extra: Int

        public init(compliant: Int, missing: Int, outdated: Int, different: Int,
                    unknown: Int, extra: Int) {
            self.compliant = compliant
            self.missing = missing
            self.outdated = outdated
            self.different = different
            self.unknown = unknown
            self.extra = extra
        }
    }

    public let machine: MachineSummary
    public let source: DesiredStateSource
    public let generated: Date
    public let apps: [AppFinding]
    public let tweaks: [TweakFinding]
    public let webApps: [WebAppFinding]
    public let extraApps: [ExtraAppFinding]
    public let warnings: [String]
    public let summary: Summary

    public init(machine: MachineSummary, source: DesiredStateSource, generated: Date = Date(),
                apps: [AppFinding], tweaks: [TweakFinding], webApps: [WebAppFinding],
                extraApps: [ExtraAppFinding], warnings: [String]) {
        self.machine = machine
        self.source = source
        self.generated = generated
        self.apps = apps
        self.tweaks = tweaks
        self.webApps = webApps
        self.extraApps = extraApps
        self.warnings = warnings
        self.summary = Summary(
            compliant: apps.filter { $0.status == .compliant }.count
                + tweaks.filter { $0.status == .compliant }.count
                + webApps.filter { $0.status == .compliant }.count,
            missing: apps.filter { $0.status == .missing }.count
                + webApps.filter { $0.status == .missing }.count,
            outdated: apps.filter { $0.status == .outdated }.count,
            different: tweaks.filter { $0.status == .different }.count,
            unknown: apps.filter { $0.status == .unknown }.count
                + tweaks.filter { $0.status == .unknown }.count,
            extra: extraApps.count)
    }
}
