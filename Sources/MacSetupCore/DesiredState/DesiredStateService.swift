import Foundation

/// The one place that knows how to turn a name typed by a person (or an MCP
/// client) into a `DesiredStateReport`. Both the CLI's `--compare-profile`
/// and the MCP server's `compare_desired_state` tool call this, so the
/// resolution and gathering logic exists exactly once.
public enum DesiredStateService {

    /// Saved profiles are tried first (a user's own name is more specific
    /// than a bundled template), then bundled Role Templates, both matched
    /// case-insensitively since this is typed by a person or an LLM.
    public static func resolve(name: String, profiles: [Profile],
                               catalog: Catalog) -> (Profile, DesiredStateSource)? {
        if let p = profiles.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return (p, DesiredStateSource(kind: .profile, name: p.name))
        }
        if let t = catalog.roleTemplateList.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return (t.asProfile, DesiredStateSource(kind: .roleTemplate, name: t.name))
        }
        return nil
    }

    /// Gathers everything the comparator needs (installed-app scan, a scoped
    /// update check, a tweak probe) for an already-resolved desired state,
    /// then calls the pure `DesiredStateComparator`. Shared by the CLI, the
    /// app's `DesiredStateEngine`, and the MCP server — none of the three
    /// duplicate this sequence.
    @MainActor
    public static func compare(desired: Profile, source: DesiredStateSource,
                               catalog: Catalog) async -> DesiredStateReport {
        let inventory = await MachineInventory.scan(catalogApps: catalog.apps)
        let requiredApps = catalog.apps.filter { desired.appIDs.contains($0.id) }
        let checker = UpdateChecker()
        await checker.check(apps: requiredApps)
        let requiredTweaks = catalog.systemDefaults.filter { desired.tweakIDs.contains($0.id) }
        let tweakStates = requiredTweaks.map(TweakComplianceProbe.check)
        return DesiredStateComparator.compare(desired: desired, source: source, catalog: catalog,
                                              inventory: inventory, updateResults: checker.results,
                                              tweakStates: tweakStates, webApps: catalog.webAppList)
    }

    /// Resolves `name`, then does the above. Returns `nil` only when `name`
    /// matches neither a saved profile nor a bundled Role Template.
    @MainActor
    public static func compare(name: String, profiles: [Profile],
                               catalog: Catalog) async -> DesiredStateReport? {
        guard let (desired, source) = resolve(name: name, profiles: profiles, catalog: catalog) else {
            return nil
        }
        return await compare(desired: desired, source: source, catalog: catalog)
    }
}
