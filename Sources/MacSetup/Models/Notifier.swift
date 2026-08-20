import Foundation
import AppKit
import UserNotifications

/// Posts a macOS notification.
///
/// Uses UserNotifications when the process is running as the app bundle, which
/// attributes the alert to MacSetup and lets the user click it. A launchd job
/// runs the same binary outside an app context where that framework refuses to
/// register, so there is an AppleScript fallback for that case.
enum Notifier {

    static func requestPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString) {
        if postViaUserNotifications(title: title, body: body, id: id) { return }
        postViaAppleScript(title: title, body: body)
    }

    private static func postViaUserNotifications(title: String, body: String, id: String) -> Bool {
        // Registering fails outside a proper app context; do not crash there.
        guard NSApp != nil, Bundle.main.bundleIdentifier != nil else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        return true
    }

    private static func postViaAppleScript(title: String, body: String) {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
        p.waitUntilExit()
    }
}
