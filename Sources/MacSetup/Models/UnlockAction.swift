import Foundation
import AppKit

/// What should happen when the user comes back to the Mac and something is
/// waiting.
///
/// The split matters: updates MacSetup can install are run through its own
/// elevated batch, which raises the standard authorisation dialog. A macOS
/// release cannot be — `softwareupdate` refuses it even as root, because Apple
/// Silicon wants a volume owner's credentials. For those the only honest move
/// is to open Software Update and let macOS do the asking.
enum UnlockAction: String, CaseIterable, Identifiable {
    case notify
    case install
    case installAndOpenSettings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notify: return "Just notify me"
        case .install: return "Install what it can"
        case .installAndOpenSettings: return "Install, and open Software Update for macOS"
        }
    }

    var installsAutomatically: Bool { self != .notify }
    var opensSoftwareUpdate: Bool { self == .installAndOpenSettings }

    static var current: UnlockAction {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "unlockAction"),
                  let a = UnlockAction(rawValue: raw) else { return .notify }
            return a
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "unlockAction") }
    }
}

/// Stops the unlock prompt turning into a nag.
///
/// Someone who locks and unlocks a dozen times a day should not be asked a
/// dozen times, so an interruption is allowed once every few hours — unless
/// what is waiting has actually changed.
@MainActor
enum UnlockThrottle {
    private static let stampKey = "unlockPromptAt"
    private static let subjectKey = "unlockPromptSubject"
    private static let interval: TimeInterval = 6 * 3600

    static func shouldAct(subject: String) -> Bool {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: subjectKey) ?? ""
        if previous != subject { return true }          // something new is waiting
        let last = defaults.object(forKey: stampKey) as? Date ?? .distantPast
        return Date().timeIntervalSince(last) > interval
    }

    static func record(subject: String) {
        UserDefaults.standard.set(Date(), forKey: stampKey)
        UserDefaults.standard.set(subject, forKey: subjectKey)
    }

    static func openSoftwareUpdate() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// Decides what to do at the moment the user comes back.
///
/// Kept out of the app's view code so the rules can be reasoned about — and
/// tested — on their own.
@MainActor
struct UnlockPlan {
    /// Staged updates MacSetup can install itself. Installing these raises the
    /// normal authorisation dialog, which is exactly the "ask again for
    /// credentials" step.
    var installable: [SystemUpdate] = []
    /// macOS releases. MacSetup cannot install these at all — Software Update
    /// has to, because only it can ask for volume owner credentials.
    var releases: [SystemUpdate] = []

    var isEmpty: Bool { installable.isEmpty && releases.isEmpty }

    /// Identifies *what* is waiting, so the throttle can tell "same thing
    /// again" from "something new arrived".
    var subject: String {
        (installable + releases).map(\.label).sorted().joined(separator: "|")
    }

    var notificationTitle: String {
        if installable.isEmpty, let r = releases.first {
            return "\(r.title) is ready to install"
        }
        if installable.count == 1 && releases.isEmpty {
            return "\(installable[0].title) is ready to install"
        }
        return "\(installable.count + releases.count) updates are ready to install"
    }

    var notificationBody: String {
        var parts: [String] = []
        if !installable.isEmpty {
            parts.append("\(installable.map(\.title).joined(separator: ", ")) — downloaded and waiting. "
                         + "Installing will restart your Mac.")
        }
        if !releases.isEmpty {
            parts.append("\(releases.map(\.title).joined(separator: ", ")) has to be installed from "
                         + "Software Update, which will ask for your password.")
        }
        return parts.joined(separator: " ")
    }

    /// Matches what was staged against what Apple still offers, and separates
    /// the two kinds. Anything staged that Apple no longer lists is dropped —
    /// it was installed some other way.
    static func make(staged: [StagedUpdate], available: [SystemUpdate]) -> UnlockPlan {
        let stagedLabels = Set(staged.map(\.label))
        var plan = UnlockPlan()
        for u in available {
            if u.isSystemRelease {
                plan.releases.append(u)
            } else if stagedLabels.contains(u.label) {
                plan.installable.append(u)
            }
        }
        return plan
    }
}
