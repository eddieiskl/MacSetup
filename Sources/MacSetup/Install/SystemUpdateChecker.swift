import Foundation

/// One pending Apple update, as reported by `softwareupdate --list`.
struct SystemUpdate: Identifiable, Hashable {
    let label: String          // what `softwareupdate -i` expects
    let title: String
    let version: String
    let sizeKiB: Int
    let recommended: Bool
    let requiresRestart: Bool

    var id: String { label }

    /// A full macOS release, as opposed to Safari or Command Line Tools. These
    /// need a volume owner's credentials on Apple Silicon, so they cannot be
    /// installed or even staged without a person present.
    var isSystemRelease: Bool {
        let t = title.lowercased()
        return t.hasPrefix("macos") || label.lowercased().hasPrefix("macos")
    }

    var sizeText: String {
        let mb = Double(sizeKiB) / 1024
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

/// Reads pending macOS and Apple software updates.
///
/// Listing needs no privileges, so it is safe to run alongside the app check.
/// Installing is a different matter: it needs root and can force a restart, so
/// nothing here installs anything on its own.
@MainActor
final class SystemUpdateChecker: ObservableObject {

    @Published private(set) var updates: [SystemUpdate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?

    /// Whether the last check actually got an answer.
    ///
    /// This matters more than it looks. A check that times out leaves
    /// `updates` empty, which is indistinguishable from "nothing pending" —
    /// so callers silently conclude the Mac is up to date, dismiss the
    /// full-screen reminder, and discard staged updates. Everything that acts
    /// on an empty list must know whether the list is trustworthy.
    @Published private(set) var lastCheckSucceeded = false

    var restartRequired: [SystemUpdate] { updates.filter(\.requiresRestart) }
    var safeToInstall: [SystemUpdate] { updates.filter { !$0.requiresRestart } }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        defer { isChecking = false; lastChecked = Date() }

        let output = await Self.runSoftwareUpdateList()
        guard let output else {
            lastError = "softwareupdate did not answer in time — what is pending is unknown."
            lastCheckSucceeded = false
            return          // deliberately leaves `updates` alone rather than emptying it
        }
        updates = Self.parse(output)
        lastCheckSucceeded = true
    }

    /// `softwareupdate --list` contacts Apple and can take a while, so it runs
    /// off the main actor with a ceiling on how long it may take.
    private static func runSoftwareUpdateList() async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            p.arguments = ["--list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return nil }

            // Measured at over 150s on a healthy Mac with a slow link to
            // Apple, which is what made a timeout look like "up to date".
            let deadline = Date().addingTimeInterval(420)
            while p.isRunning && Date() < deadline {
                usleep(200_000)
            }
            if p.isRunning { p.terminate(); return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
    }

    /// Output pairs a `* Label:` line with an indented detail line.
    static func parse(_ text: String) -> [SystemUpdate] {
        var out: [SystemUpdate] = []
        let lines = text.components(separatedBy: "\n")
        var pendingLabel: String?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                pendingLabel = String(line.dropFirst("* Label:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let label = pendingLabel, line.contains("Title:") else { continue }

            func value(_ key: String) -> String? {
                guard let r = line.range(of: "\(key): ") else { return nil }
                let rest = line[r.upperBound...]
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
            }

            let sizeRaw = value("Size") ?? "0KiB"
            let size = Int(sizeRaw.replacingOccurrences(of: "KiB", with: "")) ?? 0
            out.append(SystemUpdate(
                label: label,
                title: value("Title") ?? label,
                version: value("Version") ?? "",
                sizeKiB: size,
                recommended: (value("Recommended") ?? "NO").uppercased() == "YES",
                requiresRestart: line.lowercased().contains("action: restart")
            ))
            pendingLabel = nil
        }
        return out
    }
}
