import Foundation

/// Turns a caller's requested action ids into what's actually safe and ready
/// to hand to `InstallEngine`, applying every non-negotiable safety rail
/// *before* any execution happens — an unknown/stale id, a removal without
/// explicit confirmation, and anything needing an administrator password are
/// all filtered out here and reported back as skipped, never attempted.
///
/// Pure and side-effect-free (no `Process`, no `InstallEngine`), so it's
/// fully covered by `--test-remediation-apply` without needing to actually
/// run an install. `--apply-remediation` and the MCP server's
/// `apply_remediation` both go through this — neither re-derives these
/// rules itself.
public enum RemediationSelector {
    public struct Outcome {
        public let outcome: String
        public let detail: String

        public init(outcome: String, detail: String) {
            self.outcome = outcome
            self.detail = detail
        }
    }

    public struct Selection {
        /// Cleared to run, already resolved back to catalogue objects.
        public let apps: [CatalogApp]
        public let tweaks: [DefaultTweak]
        public let webApps: [WebApp]
        public let removals: [UninstallTarget]
        /// The QueueItem id `InstallEngine` will report each still-pending
        /// selected action under — identical to the action's `targetID` for
        /// everything except removals, which `InstallEngine` keys by
        /// `UninstallTarget.id` instead.
        public let queueItemID: [String: String]
        /// Pre-determined outcomes for ids excluded before ever reaching
        /// `InstallEngine` (stale, not applicable, removal not confirmed,
        /// needs administrator privileges).
        public let outcomes: [String: Outcome]
        /// Requested ids that survived every filter and still need a result
        /// once `InstallEngine` actually runs.
        public let pendingIDs: [String]
    }

    public static func select(requestedIDs: [String], plan: RemediationPlan, catalog: Catalog,
                              report: DesiredStateReport, confirmRemovals: Bool) -> Selection {
        let byID = Dictionary(uniqueKeysWithValues: plan.actions.map { ($0.id, $0) })
        let extraByPath = Dictionary(uniqueKeysWithValues: report.extraApps.map { ($0.path, $0) })

        var outcomes: [String: Outcome] = [:]
        var selected: [RemediationAction] = []
        var queueItemID: [String: String] = [:]

        for id in requestedIDs {
            guard let action = byID[id] else {
                outcomes[id] = Outcome(outcome: "skipped-stale",
                    detail: "No longer applicable — the Mac's state has changed since this id was seen.")
                continue
            }
            if action.kind == .removeApp && !confirmRemovals {
                outcomes[id] = Outcome(outcome: "skipped-removal-not-confirmed",
                    detail: "Pass --confirm-removals to actually remove an extra app.")
                continue
            }
            switch action.kind {
            case .installApp, .updateApp, .applyTweak, .createWebApp:
                queueItemID[action.id] = action.targetID
            case .removeApp:
                if let extra = extraByPath[action.targetID] {
                    queueItemID[action.id] = "bundle:\(extra.bundleID.isEmpty ? extra.name : extra.bundleID)"
                }
            case .manualActionRequired, .unsupported:
                outcomes[id] = Outcome(outcome: "skipped-not-applicable",
                    detail: "This finding has no automated fix — see its detail in the plan.")
                continue
            }
            selected.append(action)
        }

        let resolution = RemediationResolver.resolve(actions: selected, catalog: catalog, report: report)
        let privilegedIDs = Set(resolution.apps.filter(\.needsElevatedBatch).map(\.id))
        let safeApps = resolution.apps.filter { !privilegedIDs.contains($0.id) }

        for a in selected where privilegedIDs.contains(a.targetID) {
            outcomes[a.id] = Outcome(outcome: "skipped-privileged",
                detail: "Needs an administrator password — finish this one in the MacSetup app.")
        }

        let pendingIDs = selected.map(\.id).filter { outcomes[$0] == nil }

        return Selection(apps: safeApps, tweaks: resolution.tweaks, webApps: resolution.webApps,
                         removals: resolution.removals, queueItemID: queueItemID,
                         outcomes: outcomes, pendingIDs: pendingIDs)
    }
}
