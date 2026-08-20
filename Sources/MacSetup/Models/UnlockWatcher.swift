import AppKit
import Foundation

/// Notices when the person comes back to the Mac.
///
/// An update that needs a restart should not be installed while nobody is
/// there, and should not be nagged about at 3am either. Staging it overnight
/// and asking at the next unlock puts the interruption at a moment the user
/// chose to be present.
@MainActor
final class UnlockWatcher: ObservableObject {

    /// Fires when the screen is unlocked or the session becomes active.
    var onUnlock: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var lastFired = Date.distantPast

    func start() {
        guard tokens.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        // Posted by loginwindow when the screen is unlocked.
        tokens.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.fire() } })

        let workspace = NSWorkspace.shared.notificationCenter
        // Fast user switching back to this session, and waking from sleep.
        for name in [NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) {
                // Registered on .main, so this is already the main actor.
                [weak self] _ in MainActor.assumeIsolated { self?.fire() }
            })
        }
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for t in tokens {
            distributed.removeObserver(t)
            workspace.removeObserver(t)
        }
        tokens.removeAll()
    }

    /// Unlock, wake and session-active often arrive together; one prompt is
    /// enough.
    private func fire() {
        guard Date().timeIntervalSince(lastFired) > 30 else { return }
        lastFired = Date()
        onUnlock?()
    }

    deinit { }
}
