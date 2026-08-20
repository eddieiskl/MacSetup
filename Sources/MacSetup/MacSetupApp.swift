import SwiftUI
import AppKit

struct MacSetupApp: App {
    /// When true, closing the window leaves the app running in the menu bar
    /// instead of quitting, and the Dock icon is dropped.
    @AppStorage("liveInMenuBar") private var liveInMenuBar = true
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    /// Open filling the screen. The panes hold a lot, and a maximised window
    /// is the difference between scrolling constantly and seeing the list.
    @AppStorage("openMaximized") private var openMaximized = true
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    /// A plain AppKit window, so About behaves like every other Mac app's.
    private static var aboutWindow: NSWindow?

    @StateObject private var state = AppState()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var engine = InstallEngine()
    @StateObject private var icons = IconProvider()
    @StateObject private var checker = UpdateChecker()
    @StateObject private var metrics = WindowMetrics()
    @StateObject private var schedule = UpdateSchedule()
    @StateObject private var system = SystemUpdateChecker()
    @StateObject private var store = AppStoreChecker()
    @StateObject private var staged = PendingRestartStore()
    @StateObject private var unlock = UnlockWatcher()

    private func openAbout() {
        if let existing = Self.aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = AboutView()
            .environmentObject(state)
            .environmentObject(icons)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "About MacSetup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        Self.aboutWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    var body: some Scene {
        WindowGroup("MacSetup", id: "main") {
            ContentView()
                .environmentObject(state)
                .environmentObject(profiles)
                .environmentObject(engine)
                .environmentObject(icons)
                .environmentObject(checker)
                .frame(minWidth: 720, minHeight: 480)
                .environmentObject(metrics)
                .environmentObject(schedule)
                .environmentObject(system)
                .environmentObject(store)
                .environmentObject(staged)
                .background(WindowFitter(metrics: metrics, maximized: openMaximized))
                .task {
                    // A moment after launch, so it never competes with the
                    // first render.
                    Notifier.requestPermissionIfNeeded()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await checker.checkInBackground(apps: state.allApps)
                    await system.check()
                    await store.check()
                    staged.reconcile(with: system.updates)
                    // Same reminder as the scheduled run, so it still appears
                    // for anyone who never turned the schedule on.
                    if let nudge = SystemUpdateNudge.pending(in: system.updates) {
                        Notifier.post(title: nudge.title, body: nudge.body, id: "macsetup.osupdate")
                        SystemUpdateNudge.recordNotified()
                    }
                    considerNag()

                    // Offer any staged restart-update when the user comes back,
                    // rather than interrupting them now or rebooting overnight.
                    unlock.onUnlock = { handleUnlock() }
                    unlock.start()

                    // A snooze has to expire on its own. Without this the
                    // screen would only ever come back at the next unlock, so
                    // "remind me in an hour" could mean "never".
                    Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                        MainActor.assumeIsolated { considerNag() }
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            // Replace the stock About panel with our own.
            CommandGroup(replacing: .appInfo) {
                Button("About MacSetup") { openAbout() }
            }
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .windowSize) {
                Toggle("Open Maximised", isOn: $openMaximized)
                Button("Maximise Now") {
                    if let w = NSApp.keyWindow ?? NSApp.mainWindow,
                       let screen = w.screen ?? NSScreen.main {
                        w.setFrame(screen.visibleFrame, display: true, animate: true)
                    }
                }
                .keyboardShortcut("m", modifiers: [.command, .control])
            }
            CommandMenu("Selection") {
                Button("Select All Visible") { state.selectAllVisible() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Clear Selection") { state.clearSelection() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Reset Filters") { state.resetFilters() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Lives next to the clock, so a check that finds something is visible
        // without the window being open.
        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarView(openMain: showMainWindow)
                .environmentObject(state)
                .environmentObject(checker)
                .environmentObject(engine)
                .environmentObject(schedule)
                .environmentObject(system)
                .environmentObject(store)
                .environmentObject(staged)
        } label: {
            if checker.updates.isEmpty {
                Image(systemName: "arrow.down.circle")
            } else {
                // A count is far more useful at a glance than a plain dot.
                Label("\(checker.updates.count)", systemImage: "arrow.down.circle.fill")
            }
        }
        .menuBarExtraStyle(.menu)
    }

    /// Bring the main window back, restoring the Dock icon if it was dropped.
    /// Runs when the user comes back to the Mac.
    ///
    /// Two different things can be waiting, and they need opposite handling.
    /// Updates MacSetup staged overnight are installed here, which raises the
    /// usual authorisation dialog — the user types their password once, at a
    /// moment they chose to be present. A macOS release cannot be installed
    /// that way at all: `softwareupdate` rejects it even running as root,
    /// because Apple Silicon wants a volume owner's credentials. For that one,
    /// the most MacSetup can honestly do is open Software Update and let macOS
    /// ask for the password itself.
    /// Shows the full-screen update screen if policy says it is due.
    ///
    /// Runs at launch (which covers login and restart) and at every unlock.
    private func considerNag() {
        let policy = NagPolicy.current
        guard policy.enabled else { return }
        guard let release = system.updates.first(where: \.isSystemRelease) else {
            // Installed, or no longer offered: drop any snooze so the next
            // release starts from a clean slate.
            NagPolicy.clearSnooze()
            NagWindowController.shared.dismiss()
            return
        }
        let days = SystemUpdateNudge.age(of: release.label)
        guard policy.shouldShow(days: days, snoozedUntil: NagPolicy.snoozedUntil) else { return }

        NagWindowController.shared.onSnooze = { minutes in
            NagPolicy.snoozedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        }
        NagWindowController.shared.show(update: release, days: days, policy: policy)
    }

    private func handleUnlock() {
        Task { @MainActor in
            staged.load()

            // Unlock and wake fire many times a day. `softwareupdate --list`
            // is a network round-trip, so it is only worth re-running when
            // something is actually staged or the last answer has gone stale —
            // otherwise every unlock would cost a request and some battery.
            let stale = system.lastChecked.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
            if !staged.staged.isEmpty || stale {
                await system.check()
            }
            staged.reconcile(with: system.updates)

            if let nudge = SystemUpdateNudge.pending(in: system.updates) {
                Notifier.post(title: nudge.title, body: nudge.body, id: "macsetup.osupdate")
                SystemUpdateNudge.recordNotified()
            }

            considerNag()

            let plan = UnlockPlan.make(staged: staged.staged, available: system.updates)
            guard !plan.isEmpty else { return }
            guard UnlockThrottle.shouldAct(subject: plan.subject) else { return }
            UnlockThrottle.record(subject: plan.subject)

            Notifier.post(title: plan.notificationTitle,
                          body: plan.notificationBody,
                          id: "macsetup.staged")

            let action = UnlockAction.current
            guard action.installsAutomatically else { return }

            // Give the unlock animation a moment to finish, so the password
            // dialog does not land on a screen still fading in.
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            if !plan.installable.isEmpty && !engine.isRunning {
                showMainWindow()
                engine.runSystemUpdates(plan.installable)
                // Wait for it, so Software Update does not steal the window
                // out from under a running install.
                while engine.isRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            if action.opensSoftwareUpdate && !plan.releases.isEmpty {
                UnlockThrottle.openSoftwareUpdate()
            }
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let existing = NSApp.windows.first(where: {
            $0.canBecomeMain && !($0 is NSPanel) && $0.title == "MacSetup"
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            // No window left (it was closed): ask AppKit to reopen the default
            // one, which SwiftUI recreates from the WindowGroup.
            NSApp.sendAction(NSSelectorFromString("newWindowForTab:"), to: nil, from: nil)
            if NSApp.windows.isEmpty {
                NSWorkspace.shared.open(Bundle.main.bundleURL)
            }
        }
    }
}
