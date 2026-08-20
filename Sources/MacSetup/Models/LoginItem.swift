import Foundation
import ServiceManagement

/// Starting MacSetup when the user logs in.
///
/// Needed for anything that should happen "after a restart": the app has to be
/// running to notice, and a launchd agent that only runs on a schedule is not
/// enough.
@MainActor
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS may report `.requiresApproval` when the user has previously
    /// disabled the item in System Settings; that is not an error, it is a
    /// decision, and it is reported rather than fought.
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "starts at login"
        case .requiresApproval: return "needs approval in System Settings ▸ General ▸ Login Items"
        case .notRegistered: return "does not start at login"
        case .notFound: return "not registered with macOS"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
