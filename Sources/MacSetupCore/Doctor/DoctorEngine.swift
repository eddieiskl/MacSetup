import Foundation

/// Runs every Doctor check and assembles a report.
///
/// The read-only, shell-backed checks (`HealthCheck` conformers) are run
/// generically; the two checks that need the app catalogue and the existing
/// `SystemUpdateChecker`/`UpdateChecker` machinery are run directly here
/// rather than forced through the protocol, so this stays a small foundation
/// rather than a speculative plug-in system for checks that don't exist yet.
@MainActor
public enum DoctorEngine {

    public static let standardChecks: [any HealthCheck] = [
        MacOSVersionCheck(), ArchitectureCheck(), DiskSpaceCheck(),
        FileVaultCheck(), GatekeeperCheck(), SIPCheck(), FirewallCheck(),
    ]

    public static func run(catalogApps: [CatalogApp]) async -> DoctorReport {
        var results: [HealthCheckResult] = []
        for check in standardChecks {
            results.append(await check.run())
        }

        results.append(await pendingMacOSUpdateCheck())
        results.append(await outdatedCatalogAppsCheck(catalogApps: catalogApps))
        results.append(await rosettaDependentAppsCheck(catalogApps: catalogApps))

        return DoctorReport(machine: .current(), results: results)
    }

    private static func pendingMacOSUpdateCheck() async -> HealthCheckResult {
        let checker = SystemUpdateChecker()
        await checker.check()
        guard checker.lastCheckSucceeded else {
            return HealthCheckResult(identifier: "pending-macos-update", category: "Updates",
                                     title: "Pending macOS update",
                                     details: checker.lastError ?? "softwareupdate did not answer.",
                                     severity: .unknown)
        }
        guard let release = checker.updates.first(where: \.isSystemRelease) else {
            return HealthCheckResult(identifier: "pending-macos-update", category: "Updates",
                                     title: "Pending macOS update", details: "None pending.",
                                     severity: .healthy)
        }
        return HealthCheckResult(identifier: "pending-macos-update", category: "Updates",
                                 title: "Pending macOS update",
                                 details: "\(release.title) \(release.version) is available.",
                                 severity: .warning, remediationAvailable: true)
    }

    private static func outdatedCatalogAppsCheck(catalogApps: [CatalogApp]) async -> HealthCheckResult {
        let checker = UpdateChecker()
        await checker.check(apps: catalogApps)
        let count = checker.updates.count
        return HealthCheckResult(identifier: "outdated-catalog-apps", category: "Updates",
                                 title: "Outdated catalogue apps",
                                 details: count == 0 ? "All checked apps are current."
                                     : "\(count) app(s) have a newer version available.",
                                 severity: count == 0 ? .healthy : .warning,
                                 remediationAvailable: count > 0)
    }

    private static func rosettaDependentAppsCheck(catalogApps: [CatalogApp]) async -> HealthCheckResult {
        guard Arch.current == .appleSilicon else {
            return HealthCheckResult(identifier: "rosetta-apps", category: "Compatibility",
                                     title: "Intel-only apps", details: "This Mac is Intel — not applicable.",
                                     severity: .info)
        }
        let inventory = await MachineInventory.scan(catalogApps: catalogApps)
        let intelOnly = inventory.filter {
            BinaryArchitectureDetector.detectBundle(at: $0.path) == .intel
        }
        if intelOnly.isEmpty {
            return HealthCheckResult(identifier: "rosetta-apps", category: "Compatibility",
                                     title: "Intel-only apps", details: "None found — everything installed is arm64 or universal.",
                                     severity: .healthy)
        }
        let names = intelOnly.prefix(5).map(\.name).joined(separator: ", ")
        return HealthCheckResult(identifier: "rosetta-apps", category: "Compatibility",
                                 title: "Intel-only apps",
                                 details: "\(intelOnly.count) app(s) need Rosetta: \(names)"
                                     + (intelOnly.count > 5 ? ", and more." : "."),
                                 severity: .warning)
    }
}
