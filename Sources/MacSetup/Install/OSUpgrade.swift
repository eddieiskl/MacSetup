import Foundation
import AppKit

/// Running a macOS upgrade from a cached installer.
///
/// `startosinstall` lives inside `Install macOS <name>.app` and does the same
/// upgrade as the wizard, without the wizard. The option that makes it usable
/// here is `--passprompt`: it collects the volume owner's password through an
/// interactive prompt, so nothing has to handle a password in plaintext the
/// way `--stdinpass` would.
///
/// It still needs that password — no tool can avoid it on Apple Silicon. What
/// it removes is the clicking, and it allows the restart to be delayed rather
/// than happening the moment preparation ends.
enum OSUpgrade {

    /// Never passed, ever. `--eraseinstall` wipes every volume in the
    /// container. It has no place in an upgrade path, and naming it here is
    /// cheaper than discovering it in a bug report.
    static let forbiddenArguments = ["--eraseinstall", "--newvolumename",
                                     "--preservecontainer", "--stdinpass"]

    static func tool(in cached: OSInstallerCache.Cached) -> URL? {
        let u = cached.url.appendingPathComponent("Contents/Resources/startosinstall")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    /// The arguments for an in-place upgrade.
    ///
    /// `--forcequitapps` is deliberately optional: it discards unsaved work in
    /// open applications, which is fine on an unattended fleet machine and
    /// rude on someone's laptop mid-sentence.
    static func arguments(user: String,
                          rebootDelaySeconds: Int,
                          forceQuitApps: Bool) -> [String] {
        var a = ["--agreetolicense", "--user", user, "--passprompt"]
        // startosinstall caps this at 300 and errors above it.
        a += ["--rebootdelay", String(max(0, min(300, rebootDelaySeconds)))]
        if forceQuitApps { a.append("--forcequitapps") }
        return a
    }

    /// Reasons not to start right now. Empty means clear to proceed.
    ///
    /// These are warnings a person should see before a process that restarts
    /// their Mac several times, not decoration: an upgrade interrupted by a
    /// flat battery is how a machine ends up in recovery.
    static func preflight(cached: OSInstallerCache.Cached?) -> [String] {
        var out: [String] = []

        guard let cached else {
            return ["No macOS installer is cached — download one first."]
        }
        if !OSInstallerCache.isComplete(cached) {
            out.append("The cached installer is incomplete — it carries no payload.")
        }
        if tool(in: cached) == nil {
            out.append("This installer has no startosinstall; use the installer app instead.")
        }
        if !isAppleSigned(cached.url) {
            out.append("The installer is not signed by Apple — refusing to run it as root.")
        }
        if let batt = batteryPercent(), !onACPower() {
            out.append("Running on battery (\(batt)%). Plug in: the Mac restarts several times.")
        }
        if !hasTimeMachineDestination() {
            out.append("No Time Machine destination is configured — there is no backup to fall back on.")
        }
        if OSInstallerCache.freeBytes() < 25_000_000_000 {
            out.append("Less than 25 GB free; an upgrade needs working room.")
        }
        return out
    }

    /// Anything about to run as root gets its signature checked first.
    static func isAppleSigned(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-dv", "--verbose=2", url.path]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = Pipe()
        guard (try? p.run()) != nil else { return false }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: d, encoding: .utf8) ?? ""
        return text.contains("Authority=Apple Root CA")
            && text.contains("Software Signing")
    }

    static func onACPower() -> Bool {
        shell("/usr/bin/pmset", ["-g", "batt"]).contains("AC Power")
    }

    static func batteryPercent() -> Int? {
        let out = shell("/usr/bin/pmset", ["-g", "batt"])
        guard let r = out.range(of: #"\d+(?=%)"#, options: .regularExpression) else { return nil }
        return Int(out[r])
    }

    static func hasTimeMachineDestination() -> Bool {
        !shell("/usr/bin/tmutil", ["destinationinfo"]).contains("No destinations configured")
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// The helper handed to Terminal.
    ///
    /// `--passprompt` reads from a terminal, so this cannot run inside the app
    /// — and that is the right shape anyway: the password is typed into
    /// Terminal, and MacSetup never sees it.
    static func helperScript(tool: URL, arguments: [String], version: String) -> String {
        let quoted = arguments.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        return """
        #!/bin/bash
        #
        #  Generated by MacSetup — upgrade to macOS \(version)
        #
        #  This runs Apple's own startosinstall from the installer already on
        #  this Mac. Your password is typed into this window and read by
        #  startosinstall directly; MacSetup never sees it.
        #
        #  This UPGRADES in place. It does not erase: --eraseinstall is never
        #  passed, and you can check that on the command line printed below.
        #
        set -u

        echo
        echo "About to upgrade this Mac to macOS \(version)."
        echo "Your files, apps and settings are kept."
        echo
        echo "Command:"
        echo "  sudo '\(tool.path)' \(quoted)"
        echo
        read -r -p "Type YES to continue, anything else to cancel: " reply
        if [ "$reply" != "YES" ]; then
          echo "Cancelled. Nothing was changed."
          exit 0
        fi

        echo
        echo "sudo will ask for your password, then startosinstall will ask again"
        echo "to authorise the upgrade itself. Both prompts are macOS's own."
        echo
        sudo '\(tool.path)' \(quoted)
        rc=$?
        echo
        if [ $rc -ne 0 ]; then
          echo "startosinstall exited with $rc — nothing was upgraded."
        fi
        echo "Press return to close this window."
        read -r _
        """
    }
}

extension OSUpgrade {
    /// Hand a script to Terminal and have it actually run.
    ///
    /// `NSWorkspace.open(_:withApplicationAt:...)` brought Terminal forward but
    /// did not run the file — the user got an empty window and nothing
    /// happened. `open -a` is what the generated scripts have always used, and
    /// it works; matching it here removes the discrepancy.
    @discardableResult
    static func openInTerminal(_ script: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", script.path]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
