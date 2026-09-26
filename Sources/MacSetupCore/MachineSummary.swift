import Foundation

/// A small, stable snapshot of the Mac a report was generated on — enough to
/// make a JSON report self-describing without pulling in anything UI-specific.
public struct MachineSummary: Codable {
    public let hostName: String
    public let macOSVersion: String
    public let architecture: Arch

    public init(hostName: String, macOSVersion: String, architecture: Arch) {
        self.hostName = hostName
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }

    public static func current() -> MachineSummary {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MachineSummary(
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            architecture: .current)
    }
}
