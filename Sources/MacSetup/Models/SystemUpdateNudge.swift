import Foundation

/// Reminds the user that macOS itself is out of date.
///
/// App updates can be installed for you; a macOS release cannot — Apple Silicon
/// wants a volume owner's password, so a person has to sit down and do it. That
/// makes it the one update most likely to be ignored indefinitely, which is
/// also the one where being out of date matters most.
///
/// A single notification is the easiest thing in the world to swipe away, so
/// this remembers when a release first appeared and says so, getting more
/// direct as the weeks pass. It never nags more than once a day.
struct SystemUpdateNudge {

    /// How insistent to be, based on how long the release has been ignored.
    enum Urgency {
        case fresh          // just appeared
        case due            // a week
        case overdue        // two weeks
        case late           // a month

        static func forAge(days: Int) -> Urgency {
            if days >= 30 { return .late }
            if days >= 14 { return .overdue }
            if days >= 7 { return .due }
            return .fresh
        }
    }

    private static let seenKey = "systemUpdateFirstSeen"
    private static let notifiedKey = "systemUpdateNotifiedAt"

    /// Days since this release was first offered, recording it on first sight.
    static func age(of label: String, now: Date = Date()) -> Int {
        var seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Date] ?? [:]
        if let first = seen[label] {
            return max(0, Calendar.current.dateComponents([.day], from: first, to: now).day ?? 0)
        }
        seen[label] = now
        UserDefaults.standard.set(seen, forKey: seenKey)
        return 0
    }

    /// Forget releases Apple no longer offers, so an installed update does not
    /// keep an old first-seen date around to inflate the next one's age.
    static func forget(keeping labels: [String]) {
        let live = Set(labels)
        let seen = UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Date] ?? [:]
        let kept = seen.filter { live.contains($0.key) }
        if kept.count != seen.count { UserDefaults.standard.set(kept, forKey: seenKey) }
    }

    /// At most one OS reminder a day — past that it is noise, not a reminder.
    static func shouldNotify(now: Date = Date()) -> Bool {
        let last = UserDefaults.standard.object(forKey: notifiedKey) as? Date ?? .distantPast
        return now.timeIntervalSince(last) > 20 * 3600
    }

    static func recordNotified(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: notifiedKey)
    }

    static func title(for update: SystemUpdate, urgency: Urgency) -> String {
        switch urgency {
        case .fresh:    return "\(update.title) is available"
        case .due:      return "Time to update macOS"
        case .overdue:  return "macOS is two weeks out of date"
        case .late:     return "macOS is a month out of date"
        }
    }

    static func body(for update: SystemUpdate, urgency: Urgency, days: Int) -> String {
        let size = " (\(update.sizeText))"
        switch urgency {
        case .fresh:
            return "\(update.title)\(size) is ready to install. It needs your password, so it "
                 + "cannot be installed for you. Click to open Software Update."
        case .due:
            return "\(update.title)\(size) has been waiting \(days) days. Security fixes "
                 + "only apply once it is installed. Click to open Software Update."
        case .overdue:
            return "\(update.title)\(size) has been waiting \(days) days. This one cannot be "
                 + "installed for you — it needs your password. Click to open Software Update."
        case .late:
            return "\(update.title)\(size) has been waiting \(days) days. Please install it: "
                 + "it carries security fixes, and only you can approve it. Click to open Software Update."
        }
    }

    /// The reminder to show, or nil if there is nothing to say or it is too
    /// soon to say it again.
    static func pending(in updates: [SystemUpdate], now: Date = Date()) -> (title: String, body: String)? {
        forget(keeping: updates.map(\.label))
        guard let release = updates.first(where: \.isSystemRelease) else { return nil }
        guard shouldNotify(now: now) else { return nil }
        let days = age(of: release.label, now: now)
        let urgency = Urgency.forAge(days: days)
        return (title(for: release, urgency: urgency),
                body(for: release, urgency: urgency, days: days))
    }
}
