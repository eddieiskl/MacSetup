import Foundation

/// Configuration for the tools that can actually enforce a macOS update.
///
/// MacSetup cannot install a macOS release — Apple Silicon requires a volume
/// owner's password, and no script can supply it. Rather than keep building a
/// better nag, this emits configuration for the two things that do the job
/// properly:
///
/// * **DDM** (`com.apple.configuration.softwareupdate.enforcement.specific`),
///   pushed by an MDM. macOS enforces the deadline itself — downloading,
///   preparing, and installing under the authority of the bootstrap token
///   escrowed at enrolment. This is the only mechanism that can genuinely
///   force the update.
/// * **Nudge**, the macadmins tool, for Macs with no MDM. It only prompts, but
///   it prompts far better than anything written here, and it is maintained by
///   people who do this full time.
enum PolicyExport {

    /// A DDM declaration. `TargetLocalDateTime` is deliberately local time,
    /// not UTC: the deadline should land at a sensible hour for the person
    /// sitting at the Mac.
    static func ddmDeclaration(version: String,
                               deadline: Date,
                               identifier: String = UUID().uuidString) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")

        let payload: [String: Any] = [
            "TargetOSVersion": version,
            "TargetLocalDateTime": f.string(from: deadline),
        ]
        let doc: [String: Any] = [
            "Type": "com.apple.configuration.softwareupdate.enforcement.specific",
            "Identifier": identifier,
            "Payload": payload,
        ]
        return json(doc)
    }

    /// A Nudge preference document.
    ///
    /// Deferrals are generous rather than punitive, and the deadline is a real
    /// date rather than "days since we noticed" — Nudge takes release dates
    /// from Apple, which is the bug in MacSetup's own reminder.
    static func nudgeConfiguration(version: String,
                                   deadline: Date,
                                   aboutURL: String = "https://support.apple.com/en-us/100100") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")

        let doc: [String: Any] = [
            "optionalFeatures": [
                "acceptableApplicationBundleIDs": [],
                "aggressiveUserExperience": true,
                "attemptToFetchMajorUpgrade": false,
            ],
            "osVersionRequirements": [[
                "requiredInstallationDate": f.string(from: deadline),
                "requiredMinimumOSVersion": version,
                "aboutUpdateURL": aboutURL,
                "targetedOSVersionsRule": "default",
            ]],
            "userExperience": [
                "allowedDeferrals": 14,
                "allowedDeferralsUntilForcedSecondaryQuitButton": 20,
                "approachingRefreshCycle": 6000,
                "approachingWindowTime": 72,
                "elapsedRefreshCycle": 300,
                "imminentRefreshCycle": 600,
                "imminentWindowTime": 24,
                "initialRefreshCycle": 18000,
                "maxRandomDelayInSeconds": 1200,
                "noTimers": false,
                "nudgeRefreshCycle": 60,
            ],
            "userInterface": ["simpleMode": false, "showDeferralCount": true],
        ]
        return json(doc)
    }

    private static func json(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(
                withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
