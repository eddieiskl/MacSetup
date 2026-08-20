import Foundation

/// When the blocking update screen appears, and how easily it goes away.
///
/// Deliberately opt-in and deliberately gradual. A screen that covers every
/// display the moment an update appears trains people to click past it; one
/// that shows up after a week, and gets harder to dismiss as the weeks pass,
/// is the version that actually gets the update installed.
struct NagPolicy {
    /// Off unless someone turns it on. This is the most intrusive thing the
    /// app can do, so it is never the default.
    var enabled: Bool
    /// Days after Apple first offers the release before the screen appears.
    var afterDays: Int
    /// Days after which deferring only buys a short snooze.
    var deadlineDays: Int
    /// Minutes a deferral buys before the deadline.
    var snoozeMinutes: Int
    /// Minutes a deferral buys after it.
    var lateSnoozeMinutes: Int

    static let key = "nagPolicy"

    static var current: NagPolicy {
        let d = UserDefaults.standard
        return NagPolicy(
            enabled: d.object(forKey: "nagEnabled") as? Bool ?? false,
            afterDays: d.object(forKey: "nagAfterDays") as? Int ?? 7,
            deadlineDays: d.object(forKey: "nagDeadlineDays") as? Int ?? 14,
            snoozeMinutes: d.object(forKey: "nagSnoozeMinutes") as? Int ?? 60,
            lateSnoozeMinutes: d.object(forKey: "nagLateSnoozeMinutes") as? Int ?? 10)
    }

    func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "nagEnabled")
        d.set(afterDays, forKey: "nagAfterDays")
        d.set(deadlineDays, forKey: "nagDeadlineDays")
        d.set(snoozeMinutes, forKey: "nagSnoozeMinutes")
        d.set(lateSnoozeMinutes, forKey: "nagLateSnoozeMinutes")
    }

    /// Past the deadline, a deferral is short and says so.
    func isPastDeadline(days: Int) -> Bool { days >= deadlineDays }

    func snooze(days: Int) -> Int {
        isPastDeadline(days: days) ? lateSnoozeMinutes : snoozeMinutes
    }

    /// Whether the screen is due right now.
    ///
    /// A snooze is honoured even past the deadline. There is always a way to
    /// get back to your desk for a few minutes: an IT tool that can trap
    /// someone mid-presentation on a laptop is an incident, not a policy.
    func shouldShow(days: Int, snoozedUntil: Date?, now: Date = Date()) -> Bool {
        guard enabled else { return false }
        guard days >= afterDays else { return false }
        if let until = snoozedUntil, now < until { return false }
        return true
    }

    private static let snoozeKey = "nagSnoozedUntil"

    static var snoozedUntil: Date? {
        get { UserDefaults.standard.object(forKey: snoozeKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: snoozeKey) }
    }

    static func clearSnooze() { UserDefaults.standard.removeObject(forKey: snoozeKey) }
}
