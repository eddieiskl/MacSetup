import Foundation

/// What's known about one installed app's architecture.
///
/// Deliberately narrow for now — just enough to answer "will this need
/// Rosetta on this Mac?" Structured so later, better-understood fields
/// (supported macOS versions, deprecated APIs, system/network extensions,
/// privileged helpers, future macOS readiness) can be added without breaking
/// anything that already reads this type; none of those are implemented yet,
/// and none of their values would be more than a guess today.
public struct AppCompatibility: Codable, Identifiable {
    public var id: String { path }
    public let bundleID: String
    public let path: String
    public let architecture: BinaryArchitecture
    /// True only when the binary is Intel-only and this Mac is Apple Silicon.
    /// A universal or arm64 binary is never flagged, and a binary this tool
    /// could not read is `.unknown`, not assumed to need Rosetta.
    public let rosettaLikelyRequired: Bool

    public init(bundleID: String, path: String, architecture: BinaryArchitecture, currentArch: Arch) {
        self.bundleID = bundleID
        self.path = path
        self.architecture = architecture
        self.rosettaLikelyRequired = architecture == .intel && currentArch == .appleSilicon
    }

    public static func assess(entry: InstalledEntry, currentArch: Arch = .current) -> AppCompatibility {
        let arch = BinaryArchitectureDetector.detectBundle(at: entry.path)
        return AppCompatibility(bundleID: entry.bundleID, path: entry.path,
                                 architecture: arch, currentArch: currentArch)
    }
}
