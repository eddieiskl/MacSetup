import Foundation

/// Compares a desired state (a `Profile`, or a `RoleTemplate` via its
/// `asProfile`) against the actual Mac.
///
/// Pure and synchronous — every piece of I/O (the inventory scan, the update
/// check, the tweak probe) happens in the caller and is handed in already
/// resolved, exactly like `ScriptGenerator.build` takes fully-resolved data
/// rather than reaching out itself. That keeps this comparator trivially
/// testable and reusable from the CLI, the app, and eventually MCP.
public enum DesiredStateComparator {

    public static func compare(desired: Profile,
                                source: DesiredStateSource,
                                catalog: Catalog,
                                machine: MachineSummary = .current(),
                                inventory: [InstalledEntry],
                                updateResults: [UpdateResult],
                                tweakStates: [TweakComplianceResult],
                                webApps: [WebApp]) -> DesiredStateReport {
        var warnings: [String] = []

        let appsByID = Dictionary(uniqueKeysWithValues: catalog.apps.map { ($0.id, $0) })
        let tweaksByID = Dictionary(uniqueKeysWithValues: catalog.systemDefaults.map { ($0.id, $0) })
        let webAppsByID = Dictionary(uniqueKeysWithValues: webApps.map { ($0.id, $0) })
        let updatesByID = Dictionary(uniqueKeysWithValues: updateResults.map { ($0.id, $0) })
        let tweakStatesByID = Dictionary(uniqueKeysWithValues: tweakStates.map { ($0.tweakID, $0) })

        // MARK: Apps
        var appFindings: [AppFinding] = []
        for id in desired.appIDs {
            guard let app = appsByID[id] else {
                warnings.append("Profile requests unknown app id '\(id)' — no longer in the catalogue.")
                continue
            }
            let entry = inventory.first { $0.catalogID == app.id }
            guard let entry else {
                appFindings.append(AppFinding(id: app.id, name: app.name, status: .missing,
                                              installedVersion: nil, latestVersion: nil,
                                              detail: "Not installed."))
                continue
            }
            if let result = updatesByID[app.id] {
                switch result.state {
                case .available(let installed, let latest):
                    appFindings.append(AppFinding(id: app.id, name: app.name, status: .outdated,
                                                  installedVersion: installed, latestVersion: latest,
                                                  detail: "\(installed) installed, \(latest) available via \(result.via)."))
                case .upToDate(let v):
                    appFindings.append(AppFinding(id: app.id, name: app.name, status: .compliant,
                                                  installedVersion: v, latestVersion: v,
                                                  detail: "Up to date."))
                case .unknown(let installed, let reason):
                    appFindings.append(AppFinding(id: app.id, name: app.name, status: .unknown,
                                                  installedVersion: installed, latestVersion: nil,
                                                  detail: reason))
                }
            } else {
                appFindings.append(AppFinding(id: app.id, name: app.name, status: .unknown,
                                              installedVersion: entry.version, latestVersion: nil,
                                              detail: "Installed, but its version was not checked against the latest release."))
            }
        }

        // MARK: Extra apps — informational only, never a removal by default.
        let desiredAppIDs = Set(desired.appIDs)
        var extraFindings: [ExtraAppFinding] = []
        for entry in inventory {
            if let cid = entry.catalogID {
                guard !desiredAppIDs.contains(cid) else { continue }
                let name = appsByID[cid]?.name ?? entry.name
                extraFindings.append(ExtraAppFinding(
                    name: name, bundleID: entry.bundleID, path: entry.path, catalogID: cid,
                    detail: "In the MacSetup catalogue, but not requested by this profile."))
            } else if !entry.bundleID.isEmpty {
                extraFindings.append(ExtraAppFinding(
                    name: entry.name, bundleID: entry.bundleID, path: entry.path, catalogID: nil,
                    detail: "Not in the MacSetup catalogue."))
            }
        }

        // MARK: Tweaks
        var tweakFindings: [TweakFinding] = []
        for id in desired.tweakIDs {
            guard let tweak = tweaksByID[id] else {
                warnings.append("Profile requests unknown tweak id '\(id)' — no longer in the catalogue.")
                continue
            }
            if let state = tweakStatesByID[id] {
                tweakFindings.append(TweakFinding(id: tweak.id, name: tweak.name,
                                                  status: state.status, detail: state.detail))
            } else {
                tweakFindings.append(TweakFinding(id: tweak.id, name: tweak.name, status: .unknown,
                                                  detail: "Not probed."))
            }
        }

        // MARK: Web apps
        // Every requested web app becomes a real `<Name>.app` bundle tagged
        // `local.macsetup.webapp.<id>` — whether it launches the browser or a
        // standalone host — so its presence in the inventory is decisive.
        var webAppFindings: [WebAppFinding] = []
        for id in desired.webAppIDs {
            guard let webApp = webAppsByID[id] else {
                warnings.append("Profile requests unknown web app id '\(id)'.")
                continue
            }
            let bundleID = "local.macsetup.webapp.\(id)"
            if inventory.contains(where: { $0.bundleID == bundleID }) {
                webAppFindings.append(WebAppFinding(id: id, name: webApp.name, status: .compliant,
                                                    detail: "Installed."))
            } else {
                webAppFindings.append(WebAppFinding(id: id, name: webApp.name, status: .missing,
                                                    detail: "Not installed."))
            }
        }

        return DesiredStateReport(machine: machine, source: source, apps: appFindings,
                                  tweaks: tweakFindings, webApps: webAppFindings,
                                  extraApps: extraFindings, warnings: warnings)
    }
}
