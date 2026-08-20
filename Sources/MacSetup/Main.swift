import SwiftUI
import Foundation
import AppKit

/// Entry point. Normally launches the SwiftUI app, but also answers a small
/// command line so the same binary can be driven from a shell or an MDM script.
@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            printUsage(); exit(0)
        }
        if args.contains("--list") {
            runCLI { cat in
                for a in cat.apps.sorted(by: { ($0.category, $0.name) < ($1.category, $1.name) }) {
                    print("\(a.id.padding(toLength: 28, withPad: " ", startingAt: 0))  \(a.category.padding(toLength: 16, withPad: " ", startingAt: 0))  \(a.name)")
                }
                for w in cat.webAppList.sorted(by: { ($0.group, $0.name) < ($1.group, $1.name) }) {
                    print("\(w.id.padding(toLength: 28, withPad: " ", startingAt: 0))  \("webapp".padding(toLength: 16, withPad: " ", startingAt: 0))  \(w.name)")
                }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--emit-uninstall") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("--emit-uninstall needs a comma-separated list of ids\n".utf8))
                exit(2)
            }
            let wanted = Set(args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            runCLI { cat in
                let apps = cat.apps.filter { wanted.contains($0.id) }
                print(ScriptGenerator.buildUninstall(targets: apps.map(UninstallTarget.init)))
            }
            exit(0)
        }

        if let i = args.firstIndex(of: "--render-ui") {
            let outDir = (i + 1 < args.count && !args[i + 1].hasPrefix("-"))
                ? args[i + 1] : "/tmp/macsetup-ui"
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let state = AppState()
                let icons = IconProvider()
                let profiles = ProfileStore()
                let engine = InstallEngine()
                let checker = UpdateChecker()

                // Populate enough state that the shots show real content.
                state.selectedApps = Set(["google-chrome", "slack", "visual-studio-code",
                                          "microsoft-word", "tailscale"])
                state.selectedWebApps = Set(["gmail", "google-calendar"])
                state.selectRecommendedTweaks()
                let needed = ["google-chrome","slack","microsoft-word","visual-studio-code",
                              "rectangle","tailscale","firefox","jq","claude","nordvpn","blender","zoom"]
                for id in needed {
                    if let a = state.allApps.first(where: { $0.id == id }) { await icons.load(IconTarget(a)) }
                }
                for a in state.allApps.prefix(30) { await icons.load(IconTarget(a)) }
                for w in state.allWebApps.prefix(20) { await icons.load(IconTarget(w)) }

                let files = UIRenderer.renderAll(to: URL(fileURLWithPath: outDir),
                                                 state: state, icons: icons,
                                                 profiles: profiles, engine: engine,
                                                 checker: checker)
                for f in files { print(f) }
                print("\n\(files.count) view(s) rendered to \(outDir)")
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if let i = args.firstIndex(of: "--emit-jamf") {
            let wanted = (i + 1 < args.count && !args[i + 1].hasPrefix("-"))
                ? Set(args[i + 1].split(separator: ",").map(String.init)) : Set<String>()
            runCLI { cat in
                let apps = wanted.isEmpty ? cat.apps : cat.apps.filter { wanted.contains($0.id) }
                print(JamfExport.policyScript(apps: apps, tweaks: []))
            }
            exit(0)
        }
        if args.contains("--emit-jamf-ea") {
            print(JamfExport.extensionAttribute())
            exit(0)
        }

        if let i = args.firstIndex(of: "--schedule") {
            let sub = i + 1 < args.count ? args[i + 1] : "show"
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let sched = UpdateSchedule()
                func value(_ name: String) -> String? {
                    guard let j = args.firstIndex(of: name), j + 1 < args.count else { return nil }
                    return args[j + 1]
                }
                switch sub {
                case "set":
                    if let h = value("--hour").flatMap(Int.init) { sched.hour = max(0, min(23, h)) }
                    if let f = value("--frequency") {
                        sched.frequency = (f == "weekly") ? .weekly : .daily
                    }
                    if let a = value("--action") {
                        switch a {
                        case "notify":  sched.action = .notify
                        case "prompt":  sched.action = .installWithPrompt
                        default:        sched.action = .install
                        }
                    }
                    sched.install()
                    if let e = sched.lastError { print("  error: \(e)") }
                case "off":
                    sched.uninstall()
                    print("  schedule removed")
                case "run":
                    print("  triggering the scheduled job now")
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                    p.arguments = ["kickstart", "-p", "gui/\(getuid())/\(UpdateSchedule.label)"]
                    try? p.run(); p.waitUntilExit()
                default:
                    break
                }
                sched.refresh()
                print("  installed: \(sched.isInstalled)")
                print("  runs:      \(sched.frequency.label.lowercased()) at \(String(format: "%02d:00", sched.hour))")
                print("  action:    \(sched.action.label)")
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if args.contains("--check-system") {
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let sys = SystemUpdateChecker()
                let store = AppStoreChecker()
                await sys.check()
                await store.check()
                if let err = sys.lastError {
                    print("  \(err)")
                } else if sys.updates.isEmpty {
                    print("  macOS is up to date")
                } else {
                    for u in sys.updates {
                        let restart = u.requiresRestart ? "  [RESTART REQUIRED]" : ""
                        print("  \(u.title) \(u.version)  \(u.sizeText)\(restart)")
                    }
                    print("\n\(sys.updates.count) Apple update(s); \(sys.restartRequired.count) need a restart")
                }

                switch store.state {
                case .masMissing:
                    print("  App Store: mas is not installed (add it from the catalogue)")
                case .cannotDetect:
                    print("  App Store: \(store.receiptApps.count) app(s) found on disk, but mas cannot read their versions on this macOS")
                    for n in store.receiptApps.prefix(5) { print("      \(n)") }
                case .upToDate(let n):
                    print("  App Store: \(n) app(s), all up to date")
                case .updates(let u):
                    for a in u { print("  App Store: \(a.name)  \(a.installed) -> \(a.latest)") }
                case .notChecked:
                    break
                }
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if args.contains("--test-versions") {
            // Real assertions against VersionCompare. Every regression that has
            // actually shipped is pinned here.
            let cases: [(String, String, VersionOrder, String)] = [
                ("1.2.3", "1.2.4", .newer, "ordinary point release"),
                ("1.2.3", "1.2.3", .same, "identical"),
                ("2.0", "1.9.9", .older, "installed ahead of latest"),
                ("1.2", "1.2.0", .same, "trailing zero"),
                ("4.2.0", "5.2.0", .newer, "major bump"),
                ("3.4.12", "3.6.4", .newer, "minor beats patch width"),
                ("0.98", "v0.98", .same, "v prefix ignored"),
                ("11.58.0", "14.2.0.13656", .newer, "extra build component"),
                ("26.032.0217", "26.139.0720.0007", .newer, "zero padded"),
                // Regression: reported as an update when it is the same release
                // written two ways. This shipped and was visible to the user.
                ("7.1.5 (84650)", "7.1.5.84650", .same, "parenthesised build stamp"),
                ("7.1.5 (84650)", "7.2.0.1", .newer, "real upgrade past a build stamp"),
                // Regression: a point release against an eight digit build stamp
                // is a scheme mismatch, not an upgrade.
                ("16.112.1", "16.112.26081720", .incomparable, "build stamp vs point release"),
                ("1.0", "20240101", .incomparable, "calendar versioning mismatch"),
                // Regression: reported an update forever, because the installed
                // app carries fewer components than the download's filename.
                ("26.139.0720", "26.139.0720.0007", .same, "installed version is a prefix"),
                ("26.139.0720.0007", "26.139.0720", .same, "prefix, other way round"),
                ("1.2.3", "1.2.3.1", .same, "trailing build number only"),
            ]
            var failed = 0
            for (installed, latest, expected, label) in cases {
                let got = VersionCompare.compare(installed: installed, latest: latest)
                let ok = got == expected
                if !ok { failed += 1 }
                print("  \(ok ? "ok  " : "FAIL") \(installed) vs \(latest) -> \(got) (expected \(expected)) — \(label)")
            }
            print("\n\(cases.count - failed)/\(cases.count) version cases passed")
            exit(failed == 0 ? 0 : 1)
        }

        if args.contains("--remind-os") {
            // Posts the macOS reminder now. `--force` ignores the once-a-day
            // throttle, which is how you see what the notification looks like
            // without waiting for tomorrow.
            let force = args.contains("--force")
            // Pumping the run loop rather than blocking on a semaphore: the
            // work below is main-actor isolated, so a blocking wait on this
            // thread would deadlock against the task that needs it.
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let sys = SystemUpdateChecker()
                await sys.check()
                if force { UserDefaults.standard.removeObject(forKey: "systemUpdateNotifiedAt") }
                if let nudge = SystemUpdateNudge.pending(in: sys.updates) {
                    Notifier.post(title: nudge.title, body: nudge.body, id: "macsetup.osupdate")
                    SystemUpdateNudge.recordNotified()
                    print("posted: \(nudge.title)")
                    print("        \(nudge.body)")
                } else if !sys.updates.contains(where: \.isSystemRelease) {
                    print("no macOS release pending — nothing to remind about")
                } else {
                    print("already reminded today (use --force to post anyway)")
                }
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if let i = args.firstIndex(of: "--render-nag") {
            // Renders the update screen offscreen, so it can be reviewed
            // without covering the machine it is being built on.
            let outDir = (i + 1 < args.count && !args[i + 1].hasPrefix("-"))
                ? args[i + 1] : "/tmp/macsetup-nag"
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let release = SystemUpdate(label: "macOS Tahoe 26.7-25G220",
                                           title: "macOS Tahoe 26.7", version: "26.7",
                                           sizeKiB: 17_745_000, recommended: true,
                                           requiresRestart: true)
                let dir = URL(fileURLWithPath: outDir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, days, past, snooze) in [("nag-week", 7, false, 60),
                                                   ("nag-overdue", 21, true, 10)] {
                    let view = NagView(update: release, days: days, snoozeMinutes: snooze,
                                       pastDeadline: past, onUpdate: {}, onSnooze: { _ in })
                        .frame(width: 1280, height: 800)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        let u = dir.appendingPathComponent("\(name).png")
                        try? png.write(to: u)
                        print("wrote \(u.path)")
                    }
                }
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if let i = args.firstIndex(of: "--login-item") {
            // Scriptable so a fleet can be set up without clicking through the
            // interface. Must run from inside the .app: SMAppService registers
            // the bundle it is called from.
            let want = (i + 1 < args.count) ? args[i + 1] : "status"
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                switch want {
                case "on", "off":
                    if let err = LoginItem.set(want == "on") {
                        print("could not change it: \(err)")
                    }
                    print("login item: \(LoginItem.statusText)")
                default:
                    print("login item: \(LoginItem.statusText)")
                }
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if args.contains("--cache-os-installer") {
            // Downloads the macOS installer ahead of time. This is a large,
            // slow download, so it reports what it is about to do, refuses
            // without room, and never runs implicitly.
            let dryRun = args.contains("--dry-run")
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let sys = SystemUpdateChecker()
                await sys.check()
                guard let release = sys.updates.first(where: \.isSystemRelease) else {
                    print("no macOS release pending — nothing to cache")
                    flag.done = true; return
                }
                if let already = OSInstallerCache.cached(matching: release) {
                    print("already cached: \(already.url.path) (\(already.sizeText))")
                    flag.done = true; return
                }
                let free = ByteCountFormatter.string(fromByteCount: OSInstallerCache.freeBytes(),
                                                     countStyle: .file)
                print("\(release.title) \(release.version) — \(release.sizeText) to download, \(free) free")
                guard OSInstallerCache.hasRoomFor(sizeKiB: release.sizeKiB) else {
                    print("not enough free space, leaving it alone")
                    flag.done = true; return
                }
                if OSInstallerCache.softwareUpdateIsBusy() {
                    print("another softwareupdate is already running — not starting a second one")
                    flag.done = true; return
                }
                let cmd = (["/usr/sbin/softwareupdate"]
                           + OSInstallerCache.fetchArguments(version: release.version))
                if dryRun {
                    print("would run: \(cmd.joined(separator: " "))")
                    flag.done = true; return
                }
                // A drop partway through 18 GB is ordinary, so one attempt is
                // the wrong design. Retries only for reasons a retry can fix.
                let maxAttempts = 4
                for attempt in 1...maxAttempts {
                    print("running (attempt \(attempt)/\(maxAttempts)): \(cmd.joined(separator: " "))")
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: cmd[0])
                    p.arguments = Array(cmd.dropFirst())
                    let pipe = Pipe()
                    p.standardOutput = pipe
                    p.standardError = pipe
                    // The handler runs on its own queue, so the buffer it
                    // appends to has to be safe to touch from there.
                    let sink = OutputSink()
                    pipe.fileHandleForReading.readabilityHandler = { h in
                        let d = h.availableData
                        guard !d.isEmpty else { return }
                        sink.append(d)
                        FileHandle.standardOutput.write(d)
                    }
                    do { try p.run() } catch {
                        print("could not start softwareupdate: \(error.localizedDescription)")
                        break
                    }

                    // Watchdog. Waiting on exit alone means a wedged download
                    // is waited on forever: it keeps the process, produces no
                    // output, and never errors.
                    let watchdog = Task.detached {
                        while p.isRunning {
                            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                            guard p.isRunning else { return }
                            if OSInstallerCache.isStalled(lastOutput: sink.lastWrite) {
                                FileHandle.standardOutput.write(Data(
                                    "\nno progress for \(Int(OSInstallerCache.stallTimeout / 60)) minutes — treating it as stalled\n".utf8))
                                p.terminate()
                                return
                            }
                        }
                    }
                    p.waitUntilExit()
                    watchdog.cancel()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let captured = sink.text + (sink.wasStalled ? " stalled no progress" : "")

                    if let got = OSInstallerCache.cached(matching: release) {
                        print("\ncached: \(got.url.path) (\(got.sizeText))")
                        break
                    }
                    print("\nattempt \(attempt) finished with no installer (exit \(p.terminationStatus))")
                    guard attempt < maxAttempts,
                          OSInstallerCache.isRetryable(log: captured) else {
                        if !OSInstallerCache.isRetryable(log: captured) {
                            print("not a retryable failure — leaving it alone")
                        }
                        break
                    }
                    let wait = OSInstallerCache.backoffSeconds(attempt: attempt)
                    print("retrying in \(wait)s…")
                    try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                }
                flag.done = true
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if args.contains("--test-nag") {
            var failed = args.contains("--force-fail") ? 1 : 0
            func check(_ label: String, _ ok: Bool) {
                if !ok { failed += 1 }
                print("  \(ok ? "ok  " : "FAIL") \(label)")
            }

            let on = NagPolicy(enabled: true, afterDays: 7, deadlineDays: 14,
                               snoozeMinutes: 60, lateSnoozeMinutes: 10)
            let off = NagPolicy(enabled: false, afterDays: 7, deadlineDays: 14,
                                snoozeMinutes: 60, lateSnoozeMinutes: 10)
            let now = Date()

            check("disabled means never shown",
                  !off.shouldShow(days: 400, snoozedUntil: nil, now: now))
            check("not shown before the threshold",
                  !on.shouldShow(days: 6, snoozedUntil: nil, now: now))
            check("shown on the threshold day",
                  on.shouldShow(days: 7, snoozedUntil: nil, now: now))
            check("shown well past it",
                  on.shouldShow(days: 90, snoozedUntil: nil, now: now))

            check("an active snooze suppresses it",
                  !on.shouldShow(days: 30, snoozedUntil: now.addingTimeInterval(600), now: now))
            check("an expired snooze does not",
                  on.shouldShow(days: 30, snoozedUntil: now.addingTimeInterval(-1), now: now))

            check("a full hour before the deadline", on.snooze(days: 7) == 60)
            check("still an hour the day before", on.snooze(days: 13) == 60)
            check("short snooze on the deadline", on.snooze(days: 14) == 10)
            check("short snooze long after", on.snooze(days: 365) == 10)
            check("deadline predicate agrees",
                  !on.isPastDeadline(days: 13) && on.isPastDeadline(days: 14))

            // The safety valve. A screen with no way out can trap someone
            // mid-presentation, so a deferral must always be honoured.
            check("even a year late, a snooze still works",
                  !on.shouldShow(days: 365, snoozedUntil: now.addingTimeInterval(300), now: now))

            // The window must never be able to cover the lock screen.
            let src = (try? String(contentsOfFile: "Sources/MacSetup/Views/NagWindow.swift",
                                   encoding: .utf8)) ?? ""
            if !src.isEmpty {
                check("the screen sits at screenSaver level, not above the login window",
                      src.contains("w.level = .screenSaver") && !src.contains("CGShieldingWindowLevel"))
                check("it covers every display",
                      src.contains("for screen in NSScreen.screens"))
                check("it re-fits when displays change",
                      src.contains("didChangeScreenParametersNotification"))
                check("it always offers a way to defer", src.contains("onSnooze"))
            }

            // The cached installer must match the release being offered. An
            // installer for an older macOS would look ready while installing
            // the wrong thing.
            let tahoe = SystemUpdate(label: "macOS Tahoe 26.7-25G220", title: "macOS Tahoe 26.7",
                                     version: "26.7", sizeKiB: 17_745_000,
                                     recommended: true, requiresRestart: true)
            check("the fetch command is the documented one",
                  OSInstallerCache.fetchArguments(version: "26.7")
                  == ["--fetch-full-installer", "--full-installer-version", "26.7"])
            check("a huge release is refused when the disk is nearly full",
                  !OSInstallerCache.hasRoomFor(sizeKiB: 900_000_000))
            check("a normal release fits on a healthy disk",
                  OSInstallerCache.hasRoomFor(sizeKiB: tahoe.sizeKiB))
            check("free space is actually readable", OSInstallerCache.freeBytes() > 0)
            // Nothing is cached on this machine, so matching must say so
            // rather than volunteering an unrelated installer.
            check("no cached installer is claimed when none matches",
                  OSInstallerCache.cached().isEmpty
                  ? OSInstallerCache.cached(matching: tahoe) == nil
                  : true)

            // The real failure from this machine's first attempt: 41% in, the
            // wifi dropped. That must be retried, or an overnight cache job
            // gives up on the most ordinary failure there is.
            let realFailure = """
            Scanning for 26.7 installer
            Installing: 41.0%Install failed with error: Installation failed
            Error Domain=PKDownloadError Code=8 UserInfo={NSUnderlyingError=\
            Error Domain=NSURLErrorDomain Code=-1009 "The Internet connection appears to be offline."
            """
            check("a mid-download network drop is retried",
                  OSInstallerCache.isRetryable(log: realFailure))
            check("running out of disk is not retried",
                  !OSInstallerCache.isRetryable(log: "Error: not enough free space to continue"))
            check("an unavailable version is not retried",
                  !OSInstallerCache.isRetryable(log: "Could not find installer for version 99.9"))
            check("a clean run is not retried",
                  !OSInstallerCache.isRetryable(log: "Install finished successfully"))
            check("a download that goes quiet is treated as stalled",
                  OSInstallerCache.isStalled(lastOutput: Date().addingTimeInterval(-13 * 60)))
            check("a download that just spoke is not",
                  !OSInstallerCache.isStalled(lastOutput: Date().addingTimeInterval(-60)))
            check("a stalled run is retried, since it produces no error text",
                  OSInstallerCache.isRetryable(log: "Installing: 90.0% stalled no progress"))
            check("backoff grows and then caps",
                  OSInstallerCache.backoffSeconds(attempt: 1) == 30
                  && OSInstallerCache.backoffSeconds(attempt: 2) == 60
                  && OSInstallerCache.backoffSeconds(attempt: 3) == 120
                  && OSInstallerCache.backoffSeconds(attempt: 99) == 300)

            // Regression, from a real run: the interface let a macOS release
            // be selected, the engine queued softwareupdate -i, and it
            // downloaded ~17 GB before reporting "Failed to authenticate".
            // Every layer must refuse it independently.
            let safari2 = SystemUpdate(label: "Safari27.0", title: "Safari", version: "27.0",
                                       sizeKiB: 100_000, recommended: true, requiresRestart: true)
            let kept = InstallEngine.withoutSystemReleases([tahoe, safari2], log: { _ in })
            check("the engine drops a macOS release and keeps the rest",
                  kept.map(\.label) == ["Safari27.0"])
            var explained = ""
            _ = InstallEngine.withoutSystemReleases([tahoe], log: { explained += $0 })
            check("the engine says why, and that nothing was downloaded",
                  explained.contains("Software Update") && explained.contains("Nothing was downloaded"))

            let sysScript = ScriptGenerator.buildSystemUpdates([tahoe, safari2])
            check("the Apple-update script never mentions the release",
                  !sysScript.contains("macOS Tahoe 26.7-25G220"))
            check("the Apple-update script still installs Safari",
                  sysScript.contains("Safari27.0"))

            let mixed = ScriptGenerator.build(apps: [], tweaks: [], webApps: [],
                                              systemUpdates: [tahoe, safari2],
                                              stagedUpdates: [tahoe])
            check("the combined script never mentions the release either",
                  !mixed.contains("macOS Tahoe 26.7-25G220"))

            print("\n\(failed == 0 ? "all nag cases passed" : "\(failed) nag cases failed")")
            exit(failed == 0 ? 0 : 1)
        }

        if args.contains("--nag") {
            // Shows the screen now, whatever the policy says, so it can be
            // seen and judged before being turned on for anyone else.
            final class Flag { var done = false }
            let flag = Flag()
            Task { @MainActor in
                let sys = SystemUpdateChecker()
                await sys.check()
                guard let release = sys.updates.first(where: \.isSystemRelease) else {
                    print("no macOS release pending — nothing to show")
                    flag.done = true; return
                }
                let days = SystemUpdateNudge.age(of: release.label)
                var policy = NagPolicy.current
                policy.enabled = true
                if args.contains("--past-deadline") { policy.deadlineDays = 0 }
                NagWindowController.shared.onSnooze = { m in
                    print("snoozed for \(m) minutes"); exit(0)
                }
                NagWindowController.shared.onUpdate = { print("opened Software Update") }
                NagWindowController.shared.show(update: release, days: days, policy: policy)
                print("showing the update screen — click a button to dismiss")
            }
            while !flag.done {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if args.contains("--test-nudge") {
            var failed = args.contains("--force-fail") ? 1 : 0
            func check(_ label: String, _ ok: Bool) {
                if !ok { failed += 1 }
                print("  \(ok ? "ok  " : "FAIL") \(label)")
            }

            // Escalation boundaries. Off-by-one here means telling someone
            // their Mac is "a month out of date" on day 29.
            let cases: [(Int, SystemUpdateNudge.Urgency, String)] = [
                (0,  .fresh,   "the day it appears"),
                (6,  .fresh,   "still fresh at six days"),
                (7,  .due,     "due at exactly a week"),
                (13, .due,     "still due at thirteen days"),
                (14, .overdue, "overdue at exactly two weeks"),
                (29, .overdue, "still overdue at twenty-nine days"),
                (30, .late,    "late at exactly thirty days"),
                (400, .late,   "no level beyond late"),
            ]
            for (days, expected, label) in cases {
                check("\(label) -> \(expected)", SystemUpdateNudge.Urgency.forAge(days: days) == expected)
            }

            let release = SystemUpdate(label: "macOS Tahoe 26.7-25G220", title: "macOS Tahoe 26.7",
                                       version: "26.7", sizeKiB: 17_300_000,
                                       recommended: true, requiresRestart: true)
            let safari = SystemUpdate(label: "Safari27.0", title: "Safari", version: "27.0",
                                      sizeKiB: 100_000, recommended: true, requiresRestart: true)

            // Every message has to name the update and point somewhere useful,
            // or it is a notification that tells the user nothing.
            for u in [SystemUpdateNudge.Urgency.fresh, .due, .overdue, .late] {
                let b = SystemUpdateNudge.body(for: release, urgency: u, days: 20)
                check("the \(u) message names the release", b.contains("macOS Tahoe 26.7"))
                check("the \(u) message says where to go", b.contains("Software Update"))
                check("the \(u) message gives the size", b.contains("16.5 GB") || b.contains("GB"))
                check("the \(u) title is not empty",
                      !SystemUpdateNudge.title(for: release, urgency: u).isEmpty)
            }

            // Only a macOS release earns this reminder; Safari is installed for
            // the user, so nagging about it would be wrong.
            UserDefaults.standard.removeObject(forKey: "systemUpdateNotifiedAt")
            check("Safari alone raises no OS reminder",
                  SystemUpdateNudge.pending(in: [safari]) == nil)
            check("nothing pending raises no OS reminder",
                  SystemUpdateNudge.pending(in: []) == nil)

            UserDefaults.standard.removeObject(forKey: "systemUpdateNotifiedAt")
            check("a macOS release does raise a reminder",
                  SystemUpdateNudge.pending(in: [safari, release]) != nil)
            // Immediately afterwards it must stay quiet for the day.
            SystemUpdateNudge.recordNotified()
            check("it does not repeat within the day",
                  SystemUpdateNudge.pending(in: [release]) == nil)
            check("it speaks again after a day",
                  SystemUpdateNudge.pending(in: [release],
                                            now: Date().addingTimeInterval(21 * 3600)) != nil)

            // Cleanup, so a test run does not silence the real reminder.
            UserDefaults.standard.removeObject(forKey: "systemUpdateNotifiedAt")
            UserDefaults.standard.removeObject(forKey: "systemUpdateFirstSeen")

            print("\n\(failed == 0 ? "all nudge cases passed" : "\(failed) nudge cases failed")")
            exit(failed == 0 ? 0 : 1)
        }

        if args.contains("--test-unlock") {
            // The unlock rules decide whether a password dialog appears in
            // someone's face, so they are pinned rather than eyeballed.
            func u(_ label: String, _ title: String, restart: Bool = true) -> SystemUpdate {
                SystemUpdate(label: label, title: title, version: "1.0", sizeKiB: 1024,
                             recommended: true, requiresRestart: restart)
            }
            func staged(_ labels: [String]) -> [StagedUpdate] {
                labels.map { StagedUpdate(label: $0, title: $0, version: "1.0", stagedAt: Date()) }
            }

            let safari = u("Safari27.0", "Safari")
            let clt = u("CLTools", "Command Line Tools", restart: false)
            let tahoe = u("macOS Tahoe 26.7-25G220", "macOS Tahoe 26.7")

            // Seeded from the arguments rather than a literal, so the
            // optimiser cannot fold these assertions away — and so the harness
            // itself can be proven to report a failure when one occurs.
            var failed = args.contains("--force-fail") ? 1 : 0
            func check(_ label: String, _ ok: Bool) {
                if !ok { failed += 1 }
                print("  \(ok ? "ok  " : "FAIL") \(label)")
            }

            let both = MainActor.assumeIsolated {
                UnlockPlan.make(staged: staged(["Safari27.0"]), available: [safari, tahoe])
            }
            check("a staged non-release update is installable",
                  both.installable.map(\.label) == ["Safari27.0"])
            check("a macOS release is never installable, only reported",
                  both.releases.map(\.label) == [tahoe.label])

            let phantom = MainActor.assumeIsolated {
                UnlockPlan.make(staged: staged(["Safari26.0"]), available: [safari])
            }
            check("a staged update Apple no longer offers is dropped", phantom.isEmpty)

            let unstaged = MainActor.assumeIsolated {
                UnlockPlan.make(staged: [], available: [clt])
            }
            check("an available but unstaged update is not installed at unlock", unstaged.isEmpty)

            let releaseOnly = MainActor.assumeIsolated {
                UnlockPlan.make(staged: [], available: [tahoe])
            }
            check("a macOS release alone still prompts", !releaseOnly.isEmpty)
            check("the macOS release explains it needs Software Update",
                  releaseOnly.notificationBody.contains("Software Update"))
            check("the macOS release is not queued for installation",
                  releaseOnly.installable.isEmpty)

            check("only the settings-opening option opens Software Update",
                  UnlockAction.installAndOpenSettings.opensSoftwareUpdate
                  && !UnlockAction.install.opensSoftwareUpdate
                  && !UnlockAction.notify.opensSoftwareUpdate)
            check("notify never installs anything",
                  !UnlockAction.notify.installsAutomatically
                  && UnlockAction.install.installsAutomatically)

            check("the subject changes when a different update arrives",
                  both.subject != releaseOnly.subject)
            check("the subject is stable for the same set",
                  both.subject == MainActor.assumeIsolated {
                      UnlockPlan.make(staged: staged(["Safari27.0"]), available: [tahoe, safari]).subject
                  })

            print("\n\(failed == 0 ? "all unlock cases passed" : "\(failed) unlock cases failed")")
            exit(failed == 0 ? 0 : 1)
        }

        if args.contains("--auto-update") {
            let dryRun = args.contains("--dry-run")
            // With --allow-prompt the scheduled run may raise the standard macOS
            // authorisation dialog, so packages and Apple updates install too.
            let allowPrompt = args.contains("--allow-prompt")
            runCLI { cat in
                final class Flag { var done = false }
                let flag = Flag()
                Task { @MainActor in
                    let checker = UpdateChecker()
                    let sys = SystemUpdateChecker()
                    await checker.check(apps: cat.apps)
                    await sys.check()
                    let stamp = ISO8601DateFormatter().string(from: Date())

                    // Replacing an app while it is running can corrupt it, so
                    // anything currently open is left for next time.
                    let running = Set(NSWorkspace.shared.runningApplications
                        .compactMap { $0.bundleIdentifier })
                    let amRoot = getuid() == 0

                    var eligible: [CatalogApp] = []
                    var skippedRunning: [String] = []
                    var skippedPrivileged: [String] = []

                    for r in checker.updates {
                        guard let app = cat.apps.first(where: { $0.id == r.id }) else { continue }
                        if let b = app.bundleId, running.contains(b) {
                            skippedRunning.append(app.name); continue
                        }
                        // Without root there is nobody to approve a package at
                        // midnight, so those are reported rather than attempted.
                        if !amRoot, !allowPrompt,
                           app.source.needsRoot || app.isBrewPackage || app.needsTerminal {
                            skippedPrivileged.append(app.name); continue
                        }
                        eligible.append(app)
                    }

                    print("\(stamp): \(checker.updates.count) app update(s); \(eligible.count) installable now")
                    if !sys.updates.isEmpty {
                        // Reported, never installed here: softwareupdate needs
                        // root, and there is nobody to authorise it at midnight.
                        print("  \(sys.updates.count) Apple update(s) pending (need an administrator):")
                        for u in sys.updates {
                            print("      \(u.title) \(u.version) \(u.sizeText)"
                                  + (u.requiresRestart ? "  [restart]" : ""))
                        }
                    }
                    for n in skippedRunning { print("  skipped (running): \(n)") }
                    for n in skippedPrivileged { print("  skipped (needs an administrator): \(n)") }

                    // A macOS release gets its own reminder, on every run and
                    // regardless of what else is pending. It is the one update
                    // nobody can install on the user's behalf, so it is the one
                    // that otherwise sits ignored for months.
                    if !dryRun, let nudge = SystemUpdateNudge.pending(in: sys.updates) {
                        Notifier.post(title: nudge.title, body: nudge.body,
                                      id: "macsetup.osupdate")
                        SystemUpdateNudge.recordNotified()
                        print("  reminded: \(nudge.title)")
                    }

                    let appleCount = allowPrompt ? sys.updates.count : 0
                    if (eligible.isEmpty && appleCount == 0) || dryRun {
                        for a in eligible { print("  would install: \(a.name)") }
                        let waiting = skippedRunning + skippedPrivileged
                            + sys.updates.map { "\($0.title) (Apple)" }
                        if !dryRun, !waiting.isEmpty {
                            Notifier.post(title: "\(waiting.count) update\(waiting.count == 1 ? "" : "s") need attention",
                                          body: waiting.prefix(3).joined(separator: ", ")
                                                 + (waiting.count > 3 ? " and more" : "")
                                                 + ". Open MacSetup to install.",
                                          id: "macsetup.updates")
                        }
                        flag.done = true; return
                    }

                    var opts = ScriptOptions()
                    opts.skipInstalled = false
                    opts.logPath = "/tmp/macsetup-autoupdate.log"
                    // Never leave a dialog up indefinitely on a scheduled run.
                    if allowPrompt { opts.authTimeout = 600 }
                    let appleToInstall = allowPrompt ? sys.updates.filter { !$0.requiresRestart } : []
                    // Restart-required updates are downloaded but not installed:
                    // the bytes land overnight, the reboot waits for a human.
                    let appleToStage = allowPrompt
                        ? sys.updates.filter { $0.requiresRestart && !$0.isSystemRelease }
                        : []
                    let cannotStage = sys.updates.filter { $0.requiresRestart && $0.isSystemRelease }
                    for u in cannotStage {
                        print("  \(u.title): a macOS release needs a volume owner password — "
                              + "install it from System Settings")
                    }
                    let script = ScriptGenerator.build(apps: eligible, tweaks: [],
                                                       systemUpdates: appleToInstall,
                                                       stagedUpdates: appleToStage,
                                                       options: opts)

                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("macsetup-auto-\(UUID().uuidString.prefix(8)).sh")
                    do { try script.write(to: url, atomically: true, encoding: .utf8) }
                    catch { print("  could not stage the script: \(error)"); flag.done = true; return }

                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [url.path]
                    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                    try? p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    try? FileManager.default.removeItem(at: url)

                    let out = String(data: data, encoding: .utf8) ?? ""
                    var ok = 0, failed = 0
                    for line in out.components(separatedBy: "\n") where line.hasPrefix("@@MS|") {
                        let parts = line.dropFirst(5).split(separator: "|", maxSplits: 2)
                        guard parts.count >= 2 else { continue }
                        if parts[1] == "done" { ok += 1 }
                        if parts[1] == "failed" { failed += 1 }
                    }
                    print("  installed=\(ok) failed=\(failed)")

                    // Remember what was staged so the app can offer it at unlock.
                    if !appleToStage.isEmpty {
                        let downloaded = Set(out.components(separatedBy: "\n")
                            .filter { $0.hasPrefix("@@MS|") && $0.contains("|done|") }
                            .compactMap { line -> String? in
                                let parts = line.dropFirst(5).split(separator: "|", maxSplits: 2)
                                return parts.first.map(String.init)
                            })
                        let confirmed = appleToStage.filter { downloaded.contains($0.label) }
                        let store = PendingRestartStore()
                        store.record(confirmed)
                        if confirmed.isEmpty {
                            print("  nothing staged — the downloads did not complete")
                        } else {
                            print("  staged for the next unlock: "
                                  + confirmed.map(\.title).joined(separator: ", "))
                        }
                    }

                    var body = ok > 0 ? "Updated \(ok) app\(ok == 1 ? "" : "s")." : "No apps were updated."
                    if failed > 0 { body += " \(failed) failed." }
                    let pending = skippedRunning.count + skippedPrivileged.count + sys.updates.count
                    if pending > 0 { body += " \(pending) still need attention." }
                    Notifier.post(title: "MacSetup", body: body, id: "macsetup.autoupdate")
                    flag.done = true
                }
                while !flag.done {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
            exit(0)
        }

        if args.contains("--check-updates") {
            runCLI { cat in
                final class Flag { var done = false }
                let flag = Flag()
                Task { @MainActor in
                    let notify = args.contains("--notify")
                    let quiet = args.contains("--quiet")
                    let checker = UpdateChecker()
                    await checker.check(apps: cat.apps)

                    if notify {
                        let n = checker.updates.count
                        if n > 0 {
                            let names = checker.updates.prefix(3).map(\.name).joined(separator: ", ")
                            let more = n > 3 ? " and \(n - 3) more" : ""
                            Notifier.post(
                                title: n == 1 ? "1 update available" : "\(n) updates available",
                                body: "\(names)\(more). Open MacSetup to install.",
                                id: "macsetup.updates")
                        } else if !quiet {
                            Notifier.post(title: "MacSetup",
                                          body: "Everything is up to date.",
                                          id: "macsetup.updates")
                        }
                    }
                    if quiet {
                        let n = checker.updates.count
                        print("\(Date()): \(n) update(s) available of \(checker.results.count) installed")
                        flag.done = true
                        return
                    }
                    if checker.results.isEmpty {
                        print("No catalogue apps are installed on this Mac.")
                    } else {
                        for r in checker.results {
                            switch r.state {
                            case .available(let i, let l):
                                print("  UPDATE   \(r.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(i) -> \(l)   [\(r.via)]")
                            case .upToDate(let v):
                                print("  current  \(r.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(v)   [\(r.via)]")
                            case .unknown(let v, let why):
                                print("  unknown  \(r.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(v)   (\(why))")
                            }
                        }
                        let u = checker.updates.count
                        print("\n\(checker.results.count) installed - \(u) update\(u == 1 ? "" : "s") available, \(checker.unknowns.count) undetermined")
                        if u > 0 {
                            print("update them with:")
                            print("  MacSetup --emit-script \(checker.updates.map(\.id).joined(separator: ",")) | bash")
                        }
                    }
                    flag.done = true
                }
                while !flag.done {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
            exit(0)
        }

        if args.contains("--check-icons") {
            runCLI { cat in
                let fresh = args.contains("--no-cache")
                // The work runs on the main actor, so the main thread must keep
                // spinning its run loop rather than blocking on a semaphore.
                final class Flag { var done = false }
                let flag = Flag()

                Task { @MainActor in
                    if fresh {
                        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("MacSetup/icons")
                        try? FileManager.default.removeItem(at: dir)
                    }
                    let provider = IconProvider()
                    let apps = args.contains("--apps")
                    let targets = apps
                        ? cat.apps.map { ($0.name, IconTarget($0)) }
                        : cat.webAppList.map { ($0.name, IconTarget($0)) }

                    // Resolve in batches so 44 sites do not take 44 round trips.
                    for batch in stride(from: 0, to: targets.count, by: 8).map({
                        Array(targets[$0..<min($0 + 8, targets.count)])
                    }) {
                        await withTaskGroup(of: Void.self) { group in
                            for (_, t) in batch {
                                group.addTask { @MainActor in await provider.load(t) }
                            }
                        }
                    }

                    var tally: [String: Int] = [:]
                    var byArt: [String: [String]] = [:]
                    for (name, t) in targets {
                        let src = provider.sources[t.key]?.rawValue ?? "none"
                        tally[src, default: 0] += 1
                        let flagged = (src == "monogram" || src == "none") ? "   <- fallback" : ""
                        print("  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(src)\(flagged)")
                        if let image = provider.icon(t), src != "monogram" {
                            byArt[IconProvider.fingerprint(image), default: []].append(name)
                        }
                    }
                    print("\nsummary: " + tally.sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }.joined(separator: "  "))

                    // Two entries resolving to identical artwork is the bug that
                    // made every microsoft.com app look the same.
                    let dupes = byArt.values.filter { $0.count > 1 }
                    if dupes.isEmpty {
                        print("duplicates: none - every icon is distinct")
                    } else {
                        print("\nDUPLICATE ARTWORK:")
                        for group in dupes.sorted(by: { $0.count > $1.count }) {
                            print("  \(group.count)x  \(group.sorted().joined(separator: ", "))")
                        }
                    }
                    flag.done = true
                }

                while !flag.done {
                    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
            }
            exit(0)
        }

        if let i = args.firstIndex(of: "--emit-script") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("--emit-script needs a comma-separated list of ids\n".utf8))
                exit(2)
            }
            let wanted = Set(args[i + 1].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            runCLI { cat in
                let apps = cat.apps.filter { wanted.contains($0.id) }
                let tweaks = cat.systemDefaults.filter { wanted.contains($0.id) }
                let webApps = cat.webAppList.filter { wanted.contains($0.id) }
                let unknown = wanted
                    .subtracting(Set(apps.map(\.id)))
                    .subtracting(Set(tweaks.map(\.id)))
                    .subtracting(Set(webApps.map(\.id)))
                if !unknown.isEmpty {
                    FileHandle.standardError.write(Data("unknown ids: \(unknown.sorted().joined(separator: ", "))\n".utf8))
                }
                var opts = ScriptOptions()
                opts.strictVerify = args.contains("--strict")
                opts.standaloneWebApps = args.contains("--standalone")
                let browser = BrowserDetector.systemDefault()
                    ?? BrowserDetector.installed().first(where: \.supportsAppMode)
                print(ScriptGenerator.build(apps: apps, tweaks: tweaks, webApps: webApps,
                                            browser: browser, options: opts))
            }
            exit(0)
        }

        MacSetupApp.main()
    }

    private static func runCLI(_ body: (Catalog) -> Void) {
        do { body(try CatalogLoader.load()) }
        catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printUsage() {
        print("""
        MacSetup — provision a new Mac from a curated catalogue.

          MacSetup                          Launch the app
          MacSetup --list                   Print every catalogue id
          MacSetup --emit-script a,b,c      Print the install script for those ids
                                            (apps, web apps and tweaks all by id)
          MacSetup --auto-update [--dry-run] [--allow-prompt]
                                            Install available updates unattended;
                                            --allow-prompt also does the ones
                                            needing a password, raising a dialog
          MacSetup --schedule [show|set|off|run]
                                            Inspect or change the scheduled run
                                            e.g. --schedule set --hour 14 --action prompt
          MacSetup --check-system           List pending macOS and Apple updates
          MacSetup --check-updates [--notify] [--quiet]
                                            List installed apps with newer versions;
                                            --notify posts a macOS notification
          MacSetup --test-versions          Self-test the version comparator
          MacSetup --emit-uninstall a,b     Print a script that removes those apps
          MacSetup --emit-jamf a,b          Print a Jamf policy script for those apps
          MacSetup --emit-jamf-ea           Print the Jamf Extension Attribute script
          MacSetup --render-ui [dir]        Render the interface to PNGs offscreen
          MacSetup --check-icons [--apps] [--no-cache]
                                            Report where each icon resolves from
                                            (web apps by default, --apps for the catalogue)
          MacSetup --emit-script a,b --standalone
                                            Build web apps as standalone apps
          MacSetup --emit-script a,b --strict
                                            Fail an item on signature mismatch

        Example:
          MacSetup --emit-script google-chrome,slack,rectangle > setup.sh
          bash setup.sh
        """)
    }
}
