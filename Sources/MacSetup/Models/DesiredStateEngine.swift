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

/// Resolves `RemediationAction`s back to the catalogue objects
/// `InstallEngine` already knows how to run — the only place that needs to
/// know both Desired State and the catalogue exist at once. `InstallEngine`
/// itself stays completely unaware of any of this.
enum RemediationResolver {
    struct Resolution {
        let apps: [CatalogApp]
        let tweaks: [DefaultTweak]
        let webApps: [WebApp]
        let removals: [UninstallTarget]
    }

    static func resolve(actions: [RemediationAction], catalog: Catalog,
                        report: DesiredStateReport) -> Resolution {
        let appsByID = Dictionary(uniqueKeysWithValues: catalog.apps.map { ($0.id, $0) })
        let tweaksByID = Dictionary(uniqueKeysWithValues: catalog.systemDefaults.map { ($0.id, $0) })
        let webAppsByID = Dictionary(uniqueKeysWithValues: catalog.webAppList.map { ($0.id, $0) })
        let extraByPath = Dictionary(uniqueKeysWithValues: report.extraApps.map { ($0.path, $0) })

        var apps: [CatalogApp] = []
        var tweaks: [DefaultTweak] = []
        var webApps: [WebApp] = []
        var removals: [UninstallTarget] = []

        for a in actions {
            switch a.kind {
            case .installApp, .updateApp:
                if let app = appsByID[a.targetID] { apps.append(app) }
            case .applyTweak:
                if let t = tweaksByID[a.targetID] { tweaks.append(t) }
            case .createWebApp:
                if let w = webAppsByID[a.targetID] { webApps.append(w) }
            case .removeApp:
                if let extra = extraByPath[a.targetID] {
                    removals.append(UninstallTarget(bundleName: extra.name, bundleID: extra.bundleID))
                }
            case .manualActionRequired, .unsupported:
                break
            }
        }
        return Resolution(apps: apps, tweaks: tweaks, webApps: webApps, removals: removals)
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
