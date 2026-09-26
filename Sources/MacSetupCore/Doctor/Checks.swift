import Foundation

/// macOS version currently running.
public struct MacOSVersionCheck: HealthCheck {
    public let identifier = "macos-version"
    public init() {}
    public func run() async -> HealthCheckResult {
        let v = ProcessInfo.processInfo.operatingSystemVersionString
        return HealthCheckResult(identifier: identifier, category: "System",
                                 title: "macOS version", details: v, severity: .info)
    }
}

/// The Mac's own CPU architecture — informational, not a compatibility
/// verdict on any particular app.
public struct ArchitectureCheck: HealthCheck {
    public let identifier = "architecture"
    public init() {}
    public func run() async -> HealthCheckResult {
        let arch = Arch.current
        return HealthCheckResult(identifier: identifier, category: "System",
                                 title: "Architecture", details: arch.display, severity: .info)
    }
}

/// Free space on the boot volume.
public struct DiskSpaceCheck: HealthCheck {
    public let identifier = "disk-space"
    private let warningThresholdBytes: Int64

    public init(warningThresholdBytes: Int64 = 20_000_000_000) {
        self.warningThresholdBytes = warningThresholdBytes
    }

    public func run() async -> HealthCheckResult {
        let free = OSInstallerCache.freeBytes()
        let text = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        guard free > 0 else {
            return HealthCheckResult(identifier: identifier, category: "Storage",
                                     title: "Free disk space", details: "Could not read free space.",
                                     severity: .unknown)
        }
        let severity: HealthSeverity = free < warningThresholdBytes ? .warning : .healthy
        let detail = free < warningThresholdBytes
            ? "\(text) free — getting low, especially for a macOS installer."
            : "\(text) free."
        return HealthCheckResult(identifier: identifier, category: "Storage",
                                 title: "Free disk space", details: detail, severity: severity)
    }
}

/// FileVault status via `fdesetup status`, which needs no privileges to read.
public struct FileVaultCheck: HealthCheck {
    public let identifier = "filevault"
    public init() {}
    public func run() async -> HealthCheckResult {
        guard let out = HealthCheckShell.run("/usr/bin/fdesetup", ["status"]) else {
            return unknown()
        }
        if out.localizedCaseInsensitiveContains("FileVault is On") {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "FileVault", details: out, severity: .healthy)
        }
        if out.localizedCaseInsensitiveContains("FileVault is Off") {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "FileVault", details: out, severity: .critical)
        }
        return unknown(detail: out)
    }
    private func unknown(detail: String = "Could not read FileVault status.") -> HealthCheckResult {
        HealthCheckResult(identifier: identifier, category: "Security",
                          title: "FileVault", details: detail, severity: .unknown)
    }
}

/// Gatekeeper status via `spctl --status`, which needs no privileges to read.
public struct GatekeeperCheck: HealthCheck {
    public let identifier = "gatekeeper"
    public init() {}
    public func run() async -> HealthCheckResult {
        guard let out = HealthCheckShell.run("/usr/sbin/spctl", ["--status"]) else {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "Gatekeeper", details: "Could not read Gatekeeper status.",
                                     severity: .unknown)
        }
        let enabled = out.localizedCaseInsensitiveContains("assessments enabled")
        return HealthCheckResult(identifier: identifier, category: "Security", title: "Gatekeeper",
                                 details: out, severity: enabled ? .healthy : .warning)
    }
}

/// System Integrity Protection via `csrutil status`. Only trusted when the
/// output says so plainly — SIP's own status text changes if it can't be
/// read cleanly (e.g. from certain boot states), which this treats as
/// `.unknown` rather than a claim either way.
public struct SIPCheck: HealthCheck {
    public let identifier = "sip"
    public init() {}
    public func run() async -> HealthCheckResult {
        guard let out = HealthCheckShell.run("/usr/bin/csrutil", ["status"]) else {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "System Integrity Protection",
                                     details: "Could not read SIP status.", severity: .unknown)
        }
        if out.localizedCaseInsensitiveContains("enabled") {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "System Integrity Protection", details: out, severity: .healthy)
        }
        if out.localizedCaseInsensitiveContains("disabled") {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "System Integrity Protection", details: out, severity: .critical)
        }
        return HealthCheckResult(identifier: identifier, category: "Security",
                                 title: "System Integrity Protection", details: out, severity: .unknown)
    }
}

/// Application Firewall status. Reading it needs no privileges.
public struct FirewallCheck: HealthCheck {
    public let identifier = "firewall"
    public init() {}
    public func run() async -> HealthCheckResult {
        guard let out = HealthCheckShell.run(
            "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]) else {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "Firewall", details: "Could not read firewall status.",
                                     severity: .unknown)
        }
        if out.localizedCaseInsensitiveContains("enabled") {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "Firewall", details: out, severity: .healthy)
        }
        if out.localizedCaseInsensitiveContains("disabled") {
            return HealthCheckResult(identifier: identifier, category: "Security",
                                     title: "Firewall", details: out, severity: .warning)
        }
        return HealthCheckResult(identifier: identifier, category: "Security",
                                 title: "Firewall", details: out, severity: .unknown)
    }
}
