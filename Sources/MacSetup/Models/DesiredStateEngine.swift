import Foundation
import MacSetupCore

/// Bridges the pure Core comparator/planner into `@Published` state for
/// SwiftUI — exactly the role `UpdateChecker`/`SystemUpdateChecker` already
/// play for their own Core counterparts.
@MainActor
final class DesiredStateEngine: ObservableObject {
    @Published private(set) var report: DesiredStateReport?
    @Published private(set) var plan: RemediationPlan?
    @Published var selectedActionIDs: Set<String> = []
    @Published var includeRemovals = false
    @Published private(set) var isRunning = false

    func compare(desired: Profile, source: DesiredStateSource, catalog: Catalog) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        report = await DesiredStateService.compare(desired: desired, source: source, catalog: catalog)
        rebuildPlan()
    }

    func rebuildPlan() {
        guard let report else { plan = nil; selectedActionIDs = []; return }
        let p = RemediationPlanner.plan(from: report, includeRemovals: includeRemovals)
        plan = p
        // Removals stay unchecked until picked one at a time — never
        // auto-selected just because the "also propose removals" toggle
        // is on. Everything else defaults to selected.
        selectedActionIDs = Set(p.actions.filter { $0.kind != .removeApp }.map(\.id))
    }

    func toggleAction(_ id: String) {
        if selectedActionIDs.contains(id) { selectedActionIDs.remove(id) }
        else { selectedActionIDs.insert(id) }
    }

    var selectedActions: [RemediationAction] {
        (plan?.actions ?? []).filter { selectedActionIDs.contains($0.id) }
    }

    func reset() {
        report = nil
        plan = nil
        selectedActionIDs = []
    }
}

/// Bridges `DoctorEngine` (Core) the same way, for the Doctor pane.
@MainActor
final class DoctorRunner: ObservableObject {
    @Published private(set) var report: DoctorReport?
    @Published private(set) var isRunning = false

    func run(catalogApps: [CatalogApp]) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        report = await DoctorEngine.run(catalogApps: catalogApps)
    }
}
