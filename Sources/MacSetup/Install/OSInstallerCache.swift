import Foundation
import AppKit

/// Downloading the macOS installer ahead of time, so the update itself is quick.
///
/// The distinction that makes this work: `softwareupdate -d <label>` needs a
/// volume owner's password even to stage a release, which is why MacSetup
/// cannot do it unattended. `--fetch-full-installer` is a different route — it
/// downloads "Install macOS <name>.app" into /Applications, which is an
/// ordinary app download needing no special authorisation. The password is
/// still required to *run* it, which is exactly the step the user has to do
/// themselves anyway.
///
/// So the 18 GB wait can happen overnight, and what is left for the user is
/// the part only they can do.
enum OSInstallerCache {

    struct Cached {
        let url: URL
        let version: String
        let sizeBytes: Int64
        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    /// Any macOS installer already sitting in /Applications.
    static func cached() -> [Cached] {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []
        var out: [Cached] = []
        for name in apps where name.hasPrefix("Install macOS") && name.hasSuffix(".app") {
            let url = URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
            let plist = url.appendingPathComponent("Contents/Info.plist")
            var version = "unknown"
            if let d = try? Data(contentsOf: plist),
               let info = try? PropertyListSerialization.propertyList(from: d, format: nil)
                    as? [String: Any] {
                // DTPlatformVersion is the macOS this installs, which is what
                // matters; CFBundleShortVersionString is the app's own version.
                version = (info["DTPlatformVersion"] as? String)
                    ?? (info["CFBundleShortVersionString"] as? String) ?? "unknown"
            }
            let size = directorySize(url)
            out.append(Cached(url: url, version: version, sizeBytes: size))
        }
        return out
    }

    /// A cached installer only counts if it is the release being asked for. An
    /// installer for last year's macOS is worse than none: it would look ready
    /// while installing the wrong thing.
    static func cached(matching update: SystemUpdate) -> Cached? {
        cached().first { VersionCompare.compare(installed: $0.version,
                                                latest: update.version) == .same }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(v?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func freeBytes() -> Int64 {
        let v = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Refuses rather than filling the disk. An installer that half-downloads
    /// overnight and leaves no room to log in is worse than no installer.
    static func hasRoomFor(sizeKiB: Int, headroomGB: Int64 = 15) -> Bool {
        let need = Int64(sizeKiB) * 1024 + headroomGB * 1_000_000_000
        return freeBytes() > need
    }

    /// The command that does the download. Kept in one place so the CLI, the
    /// schedule and the docs cannot drift apart.
    static func fetchArguments(version: String) -> [String] {
        ["--fetch-full-installer", "--full-installer-version", version]
    }

    /// Whether a failed run is worth trying again.
    ///
    /// An 18 GB download over a laptop's wifi will sometimes fail partway —
    /// that is ordinary, not exceptional, so a single attempt is the wrong
    /// design. A network drop is worth retrying; being out of disk or handed a
    /// version Apple does not offer is not, and retrying those just wastes
    /// bandwidth and hides the real reason.
    static func isRetryable(log: String) -> Bool {
        let l = log.lowercased()
        let permanent = ["not enough", "no space", "could not find",
                         "not eligible", "unauthorized", "no such version"]
        if permanent.contains(where: l.contains) { return false }
        let transient = ["offline", "timed out", "timeout", "network",
                         "connection", "-1009", "-1005", "-1001",
                         "pkdownloaderror", "installation failed"]
        return transient.contains(where: l.contains)
    }

    /// Seconds to wait before attempt `n` (1-based), backing off but capped so
    /// an overnight job still gets several tries in.
    static func backoffSeconds(attempt: Int) -> Int {
        // The shift is clamped, not just the result: `1 << 98` overflows Int
        // and wraps to zero, which would turn a backoff into a tight retry
        // loop rather than a long wait.
        let steps = min(max(0, attempt - 1), 16)
        return min(300, 30 * (1 << steps))
    }

    @discardableResult
    static func open(_ cached: Cached) -> Bool {
        NSWorkspace.shared.open(cached.url)
    }
}

/// A thread-safe buffer for a subprocess's output.
///
/// `readabilityHandler` is called on a private queue, so appending to a plain
/// captured `var` from it is a data race — one the compiler now rejects
/// outright in Swift 6 mode.
final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}
