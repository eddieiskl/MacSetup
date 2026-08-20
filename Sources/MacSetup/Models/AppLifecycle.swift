import AppKit
import UserNotifications
import SwiftUI

/// Keeps the app alive in the menu bar after its window is closed.
///
/// A utility like this is more useful running quietly than being relaunched
/// every time you want to know whether anything needs updating. Closing the
/// window drops the Dock icon (activation policy `.accessory`) and leaves the
/// menu bar item; reopening restores it. Quit still quits.
final class AppLifecycle: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set from the app's preference; when false the app behaves normally.
    static var liveInMenuBar: Bool {
        UserDefaults.standard.object(forKey: "liveInMenuBar") as? Bool ?? true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.liveInMenuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without this, clicking a notification only raises the app — so a
        // message that says "click to open Software Update" would be lying.
        //
        // Guarded: outside an app bundle `current()` does not return nil, it
        // throws NSInternalInconsistencyException and takes the process with
        // it. Running the binary directly is exactly what the CLI verbs and
        // the launchd job do.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard Self.liveInMenuBar else { return }
            guard let closing = note.object as? NSWindow, closing.title == "MacSetup" else { return }
            // Wait for the close to complete before deciding whether any
            // ordinary window is left.
            DispatchQueue.main.async {
                let remaining = NSApp.windows.filter {
                    $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
                }
                if remaining.isEmpty {
                    NSApp.setActivationPolicy(.accessory)   // menu bar only
                }
            }
        }
    }

    /// Show our notifications even while MacSetup is the front app, otherwise
    /// macOS swallows them and the user sees nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Acting on a click. The macOS reminder goes straight to Software Update,
    /// which is the only thing that can install a macOS release; everything
    /// else opens MacSetup.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            if id == "macsetup.osupdate" {
                UnlockThrottle.openSoftwareUpdate()
            } else {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            completionHandler()
        }
    }

    /// Clicking the Dock icon (when there is one) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        return true
    }
}
