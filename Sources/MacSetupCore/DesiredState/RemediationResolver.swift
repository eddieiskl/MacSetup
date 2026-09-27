import Foundation

/// Resolves `RemediationAction`s back to the catalogue objects
/// `InstallEngine` already knows how to run — the only place that needs to
/// know both Desired State and the catalogue exist at once. `InstallEngine`
/// itself stays completely unaware of any of this.
///
/// Lives in Core (rather than the app target, where it started) so the CLI
/// and MCP server can reach it too, not just the SwiftUI "Apply" button.
public enum RemediationResolver {
    public struct Resolution {
        public let apps: [CatalogApp]
        public let tweaks: [DefaultTweak]
        public let webApps: [WebApp]
        public let removals: [UninstallTarget]
    }

    public static func resolve(actions: [RemediationAction], catalog: Catalog,
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
