import Foundation

struct AppStoreUpdate: Identifiable, Hashable {
    let id: String        // App Store numeric id
    let name: String
    let installed: String
    let latest: String
}

/// App Store updates, via the `mas` command line tool.
///
/// `mas` reads Spotlight metadata to work out what is installed, so a Mac whose
/// App Store apps have never been indexed reports nothing at all. That is not
/// the same as "everything is up to date", and saying so would be a lie — hence
/// a distinct state for it.
@MainActor
final class AppStoreChecker: ObservableObject {

    enum State: Equatable {
        case notChecked
        case masMissing
        /// mas is installed but cannot see the apps. On recent macOS the
        /// Spotlight attribute it relies on (kMDItemAppStoreHasReceipt) is no
        /// longer populated, and no amount of reindexing fixes that — so this
        /// is reported honestly rather than as "up to date".
        case cannotDetect
        case upToDate(installed: Int)
        case updates([AppStoreUpdate])
    }

    @Published private(set) var state: State = .notChecked
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    /// App Store apps found on disk by their receipt, which does not depend on
    /// Spotlight and therefore always works.
    @Published private(set) var receiptApps: [String] = []

    var updates: [AppStoreUpdate] {
        if case .updates(let u) = state { return u }
        return []
    }

    static var masPath: String? {
        ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false; lastChecked = Date() }

        receiptApps = Self.findAppStoreApps()

        guard let mas = Self.masPath else { state = .masMissing; return }

        let outdated = await Self.run(mas, ["outdated"])
        let listed = await Self.run(mas, ["list"])

        let parsed = Self.parse(outdated ?? "")
        if !parsed.isEmpty { state = .updates(parsed); return }

        let visible = Self.countEntries(listed ?? "")
        // mas seeing nothing while receipts exist on disk means it cannot detect
        // them, not that they are current.
        if visible == 0 && !receiptApps.isEmpty {
            state = .cannotDetect
        } else {
            state = .upToDate(installed: max(visible, receiptApps.count))
        }
    }

    /// Every app carrying an App Store receipt. Reading the filesystem avoids
    /// Spotlight entirely, so this is dependable where `mas list` is not.
    static func findAppStoreApps() -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        for dir in ["/Applications", "\(NSHomeDirectory())/Applications"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let receipt = "\(dir)/\(entry)/Contents/_MASReceipt/receipt"
                if fm.fileExists(atPath: receipt) { found.append(String(entry.dropLast(4))) }
            }
        }
        return found.sorted()
    }

    private static func run(_ tool: String, _ args: [String]) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            // Stops mas kicking off a background index and printing a wall of
            // warnings every time it is called.
            var env = ProcessInfo.processInfo.environment
            env["MAS_NO_AUTO_INDEX"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            guard (try? p.run()) != nil else { return nil }
            let deadline = Date().addingTimeInterval(90)
            while p.isRunning && Date() < deadline { usleep(150_000) }
            if p.isRunning { p.terminate(); return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
    }

    private static func countEntries(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { line in
            guard let first = line.first else { return false }
            return first.isNumber
        }.count
    }

    /// `497799835 Xcode (14.0 -> 14.1)`
    static func parse(_ text: String) -> [AppStoreUpdate] {
        var out: [AppStoreUpdate] = []
        let pattern = #"^(\d+)\s+(.+?)\s+\((.+?)\s*->\s*(.+?)\)\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = re.firstMatch(in: line, range: range) else { continue }
            func group(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: line) else { return "" }
                return String(line[r]).trimmingCharacters(in: .whitespaces)
            }
            out.append(AppStoreUpdate(id: group(1), name: group(2),
                                      installed: group(3), latest: group(4)))
        }
        return out
    }
}
