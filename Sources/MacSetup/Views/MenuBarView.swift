import SwiftUI
import AppKit

/// Contents of the menu bar item.
///
/// The point of living in the menu bar is that the check keeps happening and
/// the result is visible without the window being open, so this shows the
/// current state and the two actions worth having to hand.
struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var checker: UpdateChecker
    @EnvironmentObject var engine: InstallEngine
    @EnvironmentObject var schedule: UpdateSchedule
    @EnvironmentObject var staged: PendingRestartStore
    var openMain: () -> Void

    var body: some View {
        if checker.isChecking {
            Text("Checking for updates…")
        } else if checker.updates.isEmpty {
            Text(checker.lastChecked == nil ? "No check run yet" : "Everything is up to date")
        } else {
            Text(checker.updates.count == 1
                 ? "1 update available"
                 : "\(checker.updates.count) updates available")
            Divider()
            ForEach(checker.updates.prefix(8)) { r in
                if case .available(let installed, let latest) = r.state {
                    Button("\(r.name)  \(installed) → \(latest)") { openMain() }
                }
            }
            if checker.updates.count > 8 {
                Text("and \(checker.updates.count - 8) more…")
            }
        }

        Divider()

        Button(checker.isChecking ? "Checking…" : "Check Now") {
            Task { await checker.check(apps: state.allApps) }
        }
        .disabled(checker.isChecking)

        if !checker.updates.isEmpty {
            Button("Install \(checker.updates.count) Update\(checker.updates.count == 1 ? "" : "s")…") {
                openMain()
            }
            .disabled(engine.isRunning)
        }

        // Anything downloaded overnight is waiting on the user, so say so here
        // rather than only in a notification they may have missed.
        if !staged.staged.isEmpty {
            Divider()
            Text(staged.staged.count == 1
                 ? "Waiting for a restart: \(staged.staged[0].title)"
                 : "\(staged.staged.count) updates waiting for a restart")
            Button("Install and Restart…") { openMain() }
                .disabled(engine.isRunning)
        }

        Divider()

        Button("Open MacSetup") { openMain() }
        if let when = checker.lastChecked {
            Text("Last checked \(when.formatted(date: .omitted, time: .shortened))")
        }
        if schedule.isInstalled {
            Text("Scheduled \(schedule.frequency.label.lowercased()) at \(String(format: "%02d:00", schedule.hour))")
        }

        Divider()
        Button("Quit MacSetup") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
