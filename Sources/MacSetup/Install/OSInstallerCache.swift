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

    /// The payload every real installer carries. Without it the app is a stub:
    /// it looks like an installer, launches like one, and then tries to
    /// download the whole release at the worst possible moment.
    static func isComplete(_ c: Cached) -> Bool {
        let shared = c.url.appendingPathComponent("Contents/SharedSupport")
        let dmg = shared.appendingPathComponent("SharedSupport.dmg")
        guard FileManager.default.fileExists(atPath: dmg.path) else { return false }
        // A stub is tens of megabytes; the real thing is tens of gigabytes.
        return c.sizeBytes > 8_000_000_000
    }

    /// A cached installer only counts if it is the release being asked for and
    /// is actually complete.
    ///
    /// Both halves were learned the hard way. An installer for last year's
    /// macOS would look ready while installing the wrong thing; and an
    /// interrupted fetch leaves a ~30 MB stub in /Applications that satisfies
    /// a version check while containing nothing at all.
    static func cached(matching update: SystemUpdate) -> Cached? {
        cached().first {
            VersionCompare.compare(installed: $0.version, latest: update.version) == .same
            && isComplete($0)
        }
    }

    /// A stub or half-written installer, which should be removed before
    /// fetching again rather than left to mislead.
    static func incomplete(matching update: SystemUpdate) -> Cached? {
        cached().first {
            VersionCompare.compare(installed: $0.version, latest: update.version) == .same
            && !isComplete($0)
        }
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

    /// Fetching is handed to Terminal rather than run in-process.
    ///
    /// It used to be supervised here: a watchdog, a stall detector, retry
    /// classification, a busy check. That machinery caused four bugs in a day
    /// — it killed a healthy download at 87%, accepted the ~30 MB stub that
    /// left behind, mis-classified failures, and made `--dry-run` delete
    /// things. All of it existed to guess at progress from outside.
    ///
    /// In a Terminal window the user sees Apple's own percentage, can stop it
    /// with control-C, and can run it again. No guessing, and nothing to get
    /// wrong.
    static func fetchScript(version: String, sizeText: String) -> String {
        """
        #!/bin/bash
        #
        #  Generated by MacSetup — download the macOS \(version) installer
        #
        #  This is Apple's own softwareupdate. Progress below is theirs, not a
        #  guess made from outside the process. Control-C stops it; running it
        #  again resumes.
        #
        set -u
        echo
        echo "Downloading the macOS \(version) installer (about \(sizeText))."
        echo "It lands in /Applications when finished."
        echo
        /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version '\(version)'
        rc=$?
        echo
        if [ $rc -ne 0 ]; then
          echo "softwareupdate exited with $rc."
          echo "If an incomplete \"Install macOS\" app is left in /Applications,"
          echo "remove it before trying again — it is written as root:"
          echo "    sudo rm -rf \"/Applications/Install macOS \"*.app"
        fi
        echo "Press return to close this window."
        read -r _
        """
    }

    @discardableResult
    static func open(_ cached: Cached) -> Bool {
        NSWorkspace.shared.open(cached.url)
    }
}
