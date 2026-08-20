import SwiftUI
import AppKit

struct MacSetupApp: App {
    /// When true, closing the window leaves the app running in the menu bar
    /// instead of quitting, and the Dock icon is dropped.
    @AppStorage("liveInMenuBar") private var liveInMenuBar = true
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
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
                .background(WindowFitter(metrics: metrics))
                .task {
                    // A moment after launch, so it never competes with the
                    // first render.
                    Notifier.requestPermissionIfNeeded()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await checker.checkInBackground(apps: state.allApps)
                    await system.check()
                    await store.check()
                    staged.reconcile(with: system.updates)

                    // Offer any staged restart-update when the user comes back,
                    // rather than interrupting them now or rebooting overnight.
                    unlock.onUnlock = {
                        Task { @MainActor in
                            staged.load()
                            guard !staged.staged.isEmpty else { return }
                            let names = staged.staged.map(\.title).joined(separator: ", ")
                            Notifier.post(
                                title: staged.staged.count == 1
                                    ? "\(staged.staged[0].title) is ready to install"
                                    : "\(staged.staged.count) updates are ready to install",
                                body: "\(names) — downloaded and waiting. Installing will restart your Mac.",
                                id: "macsetup.staged")
                        }
                    }
                    unlock.start()
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
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            if NSApp.windows.isEmpty {
                NSWorkspace.shared.open(Bundle.main.bundleURL)
            }
        }
    }
}
