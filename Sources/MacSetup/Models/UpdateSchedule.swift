import Foundation

/// Manages a launchd job that checks for updates even when MacSetup is closed.
///
/// An admin tool that only notices updates while it happens to be open is not
/// much use, so the same binary is run on a schedule by launchd and posts a
/// notification if anything is out of date.
@MainActor
final class UpdateSchedule: ObservableObject {

    enum Frequency: String, CaseIterable, Identifiable {
        case daily, weekly
        var id: String { rawValue }
        var seconds: Int { self == .daily ? 86_400 : 604_800 }
        var label: String { self == .daily ? "Daily" : "Weekly" }
    }

    /// What the scheduled run should do when it finds something.
    enum Action: String, CaseIterable, Identifiable {
        case notify, install, installWithPrompt
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notify: return "Notify me"
            case .install: return "Install what needs no password"
            case .installWithPrompt: return "Install everything (ask for password)"
            }
        }
        var arguments: [String] {
            switch self {
            case .notify: return ["--check-updates", "--notify", "--quiet"]
            case .install: return ["--auto-update"]
            case .installWithPrompt: return ["--auto-update", "--allow-prompt"]
            }
        }
    }

    static let label = "local.macsetup.updatecheck"

    @Published var isInstalled = false
    @Published var frequency: Frequency = .daily
    @Published var action: Action = .notify
    /// Hour of day for the run. Midnight by default — the machine is idle and
    /// nothing is likely to be open, which matters because a running app is
    /// skipped rather than replaced underneath the user.
    @Published var hour: Int = 0
    @Published var lastError: String?

    private var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(Self.label).plist")
    }

    init() { refresh() }

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: plistURL.path)
        guard isInstalled, let d = NSDictionary(contentsOf: plistURL) else { return }
        if let argv = d["ProgramArguments"] as? [String] {
            if argv.contains("--allow-prompt") { action = .installWithPrompt }
            else if argv.contains("--auto-update") { action = .install }
            else { action = .notify }
        }
        if let cal = d["StartCalendarInterval"] as? [String: Any] {
            hour = cal["Hour"] as? Int ?? 0
            frequency = cal["Weekday"] != nil ? .weekly : .daily
        } else if let interval = d["StartInterval"] as? Int {
            frequency = interval >= Frequency.weekly.seconds ? .weekly : .daily
        }
    }

    /// The binary inside the running app bundle, so the job survives the app
    /// being moved as long as it is not deleted.
    private var executablePath: String? {
        guard let exe = Bundle.main.executableURL?.path,
              FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        return exe
    }

    func install() {
        lastError = nil
        guard let exe = executablePath else {
            lastError = "Could not locate the MacSetup binary."
            return
        }
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A calendar interval rather than a repeating countdown, so it runs at a
        // predictable hour. launchd also catches up on a missed run once the Mac
        // wakes, which a StartInterval does not do reliably.
        var calendar: [String: Any] = ["Hour": hour, "Minute": 0]
        if frequency == .weekly { calendar["Weekday"] = 0 }   // Sunday

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [exe] + action.arguments,
            "StartCalendarInterval": calendar,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "StandardOutPath": "/tmp/macsetup-updatecheck.log",
            "StandardErrorPath": "/tmp/macsetup-updatecheck.log",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                            format: .xml, options: 0) else {
            lastError = "Could not build the launch agent."
            return
        }
        do { try data.write(to: plistURL, options: .atomic) }
        catch { lastError = error.localizedDescription; return }

        bootout()
        if !bootstrap() { lastError = "launchctl refused to load the job." }
        refresh()
    }

    func uninstall() {
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
        refresh()
    }

    /// Run the scheduled job immediately, so it can be tested without waiting
    /// for the clock — and without hand-editing the plist, which is how the
    /// configured hour got clobbered once already.
    func runNow() {
        lastError = nil
        guard isInstalled else { lastError = "The schedule is not installed."; return }
        if !run(["kickstart", "-p", "gui/\(getuid())/\(Self.label)"]) {
            lastError = "launchctl could not start the job."
        }
    }

    /// What launchd will actually do, read back from disk rather than assumed.
    var summary: String {
        guard isInstalled else { return "Not scheduled." }
        return "\(frequency.label) at \(String(format: "%02d:00", hour)) — \(action.label.lowercased())"
    }

    @discardableResult
    private func bootstrap() -> Bool {
        run(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func bootout() {
        _ = run(["bootout", "gui/\(getuid())/\(Self.label)"])
    }

    @discardableResult
    private func run(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
