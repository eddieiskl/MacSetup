import Foundation

public enum RemediationActionKind: String, Codable {
    case installApp
    case updateApp
    case applyTweak
    case createWebApp
    case removeApp
    case manualActionRequired
    case unsupported
}

/// One proposed change. This describes intent only — nothing here executes
/// anything; turning a plan into an actual run is the caller's job, via
/// `InstallEngine`, which stays completely unaware that Desired State exists.
///
/// `removeApp` is the only kind that can carry `requiresExplicitApproval =
/// true`, and `RemediationPlanner` never emits one unless the caller opted in
/// — extras are informational by default, matching MacSetup's existing rule
/// that nothing is uninstalled without a separate, explicit selection.
public struct RemediationAction: Codable, Identifiable {
    public let id: String
    public let kind: RemediationActionKind
    /// The catalogue app/tweak/web-app id this refers back to, or an
    /// `ExtraAppFinding`'s path for `removeApp`.
    public let targetID: String
    public let title: String
    public let detail: String
    public let requiresExplicitApproval: Bool

    public init(id: String, kind: RemediationActionKind, targetID: String, title: String,
                detail: String, requiresExplicitApproval: Bool = false) {
        self.id = id
        self.kind = kind
        self.targetID = targetID
        self.title = title
        self.detail = detail
        self.requiresExplicitApproval = requiresExplicitApproval
    }
}

public struct RemediationPlan: Codable {
    public let source: DesiredStateSource
    public let generated: Date
    public let actions: [RemediationAction]

    public init(source: DesiredStateSource, generated: Date = Date(), actions: [RemediationAction]) {
        self.source = source
        self.generated = generated
        self.actions = actions
    }
}

/// Builds a `RemediationPlan` from a `DesiredStateReport`. Deterministic, no
/// shell execution of any kind — desired-state never gets its own command
/// line to run; it only ever proposes actions that go through the existing,
/// already-reviewed install/update/tweak machinery.
public enum RemediationPlanner {

    public static func plan(from report: DesiredStateReport, includeRemovals: Bool = false) -> RemediationPlan {
        var actions: [RemediationAction] = []

        for f in report.apps {
            switch f.status {
            case .missing:
                actions.append(RemediationAction(id: "install-\(f.id)", kind: .installApp,
                                                 targetID: f.id, title: "Install \(f.name)",
                                                 detail: f.detail))
            case .outdated:
                actions.append(RemediationAction(id: "update-\(f.id)", kind: .updateApp,
                                                 targetID: f.id, title: "Update \(f.name)",
                                                 detail: f.detail))
            case .unknown:
                actions.append(RemediationAction(id: "manual-\(f.id)", kind: .manualActionRequired,
                                                 targetID: f.id,
                                                 title: "Check \(f.name) manually",
                                                 detail: f.detail))
            case .compliant, .different, .extra, .notApplicable:
                break
            }
        }

        for f in report.tweaks {
            switch f.status {
            case .different:
                actions.append(RemediationAction(id: "tweak-\(f.id)", kind: .applyTweak,
                                                 targetID: f.id, title: "Apply \(f.name)",
                                                 detail: f.detail))
            case .unknown:
                actions.append(RemediationAction(id: "manual-tweak-\(f.id)", kind: .unsupported,
                                                 targetID: f.id,
                                                 title: "\(f.name) can't be verified automatically",
                                                 detail: f.detail))
            case .compliant, .missing, .outdated, .extra, .notApplicable:
                break
            }
        }

        for f in report.webApps {
            if f.status == .missing {
                actions.append(RemediationAction(id: "webapp-\(f.id)", kind: .createWebApp,
                                                 targetID: f.id, title: "Create \(f.name)",
                                                 detail: f.detail))
            }
        }

        if includeRemovals {
            for extra in report.extraApps {
                actions.append(RemediationAction(
                    id: "remove-\(extra.bundleID.isEmpty ? extra.path : extra.bundleID)",
                    kind: .removeApp, targetID: extra.path,
                    title: "Remove \(extra.name)", detail: extra.detail,
                    requiresExplicitApproval: true))
            }
        }

        return RemediationPlan(source: report.source, actions: actions)
    }
}
