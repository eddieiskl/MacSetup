import Foundation
import SwiftUI

// MARK: - Queue item state

enum ItemState: Equatable {
    case pending
    case running
    case resolving
    case downloading(Int)     // percentage, or -1 when the size is unknown
    case verifying
    case installing
    case awaitingAuth
    case done
    case failed
    case skipped

    var isTerminal: Bool {
        switch self { case .done, .failed, .skipped: return true; default: return false }
    }

    var label: String {
        switch self {
        case .pending:      return "Waiting"
        case .running:      return "Starting"
        case .resolving:    return "Finding latest version"
        case .downloading(let p): return p < 0 ? "Downloading" : "\(p)%"
        case .verifying:    return "Verifying signature"
        case .installing:   return "Installing"
        case .awaitingAuth: return "Needs authorisation"
        case .done:         return "Installed"
        case .failed:       return "Failed"
        case .skipped:      return "Already installed"
        }
    }

    var symbol: String {
        switch self {
        case .pending:      return "circle.dashed"
        case .running:      return "circle.dotted"
        case .resolving:    return "magnifyingglass"
        case .downloading:  return "arrow.down.circle"
        case .verifying:    return "checkmark.shield"
        case .installing:   return "shippingbox"
        case .awaitingAuth: return "lock"
        case .done:         return "checkmark.circle.fill"
        case .failed:       return "xmark.octagon.fill"
        case .skipped:      return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .done:         return .green
        case .failed:       return .red
        case .skipped:      return .secondary
        case .awaitingAuth: return .orange
        case .pending:      return .secondary
        default:            return .accentColor
        }
    }
}

struct QueueItem: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    var state: ItemState = .pending
    var detail: String = ""
    /// Whatever the signature check actually observed, shown in the UI.
    var signature: String = ""
}

// MARK: - Engine

@MainActor
final class InstallEngine: ObservableObject {

    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var rawLog = ""
    @Published private(set) var finished = false
    @Published private(set) var summary: (ok: Int, failed: Int, skipped: Int)? = nil
    @Published var showAuthNotice = false
    @Published private(set) var isPaused = false

    private var process: Process?
    private var tailTask: Task<Void, Never>?
    private var logURL: URL?
    private var pauseURL: URL?
    private var readOffset: UInt64 = 0
    private var partial = ""

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        let done = items.filter { $0.state.isTerminal }.count
        return Double(done) / Double(items.count)
    }

    var counts: (done: Int, failed: Int, skipped: Int, remaining: Int) {
        var d = 0, f = 0, s = 0
        for i in items {
            switch i.state {
            case .done: d += 1
            case .failed: f += 1
            case .skipped: s += 1
            default: break
            }
        }
        return (d, f, s, items.count - d - f - s)
    }

    // MARK: Run

    /// Builds and runs the script.
    ///
    /// The engine generates the script itself rather than accepting one, because
    /// the script has to write its status lines to exactly the log file the
    /// engine tails. When those two drifted apart, the elevated package batch
    /// logged to a different file and every .pkg install was reported as failed
    /// even though it had installed correctly.
    func run(apps: [CatalogApp],
             tweaks: [DefaultTweak],
             webApps: [WebApp] = [],
             systemUpdates: [SystemUpdate] = [],
             browser: BrowserInfo? = nil,
             options: ScriptOptions = ScriptOptions()) {
        guard !isRunning else { return }

        // A macOS release can never be installed by this app: softwareupdate
        // rejects it even as root, because Apple Silicon wants a volume
        // owner's credentials. Attempting it downloads gigabytes first and
        // *then* fails, so it is refused here rather than anywhere later —
        // this is the layer that stops the wasted download, whatever the
        // interface allowed the user to select.
        let systemUpdates = Self.withoutSystemReleases(systemUpdates, log: { appendLog($0) })

        items = apps.map {
            QueueItem(id: $0.id, name: $0.name, subtitle: $0.source.shortLabel)
        } + webApps.map {
            QueueItem(id: $0.id, name: $0.name, subtitle: "Web app · \($0.host)")
        } + systemUpdates.map {
            QueueItem(id: $0.label, name: $0.title,
                      subtitle: "Apple · \($0.sizeText)" + ($0.requiresRestart ? " · needs a restart" : ""))
        } + tweaks.map {
            QueueItem(id: $0.id, name: $0.name, subtitle: $0.group)
        }
        rawLog = ""
        finished = false
        summary = nil
        readOffset = 0
        partial = ""
        showAuthNotice = apps.contains { $0.needsRoot }

        let dir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString.prefix(8)
        let scriptURL = dir.appendingPathComponent("macsetup-\(stamp).sh")
        let log = dir.appendingPathComponent("macsetup-\(stamp).log")
        logURL = log

        let pause = dir.appendingPathComponent("macsetup-\(stamp).pause")
        pauseURL = pause
        try? FileManager.default.removeItem(at: pause)
        isPaused = false

        var opts = options
        opts.logPath = log.path              // the one place this must agree
        opts.pausePath = pause.path
        let script = ScriptGenerator.build(apps: apps, tweaks: tweaks, webApps: webApps,
                                           systemUpdates: systemUpdates,
                                           browser: browser, options: opts)

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            appendLog("Could not stage the install script: \(error.localizedDescription)")
            markAllFailed()
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The elevated package batch writes to the same log, so route everything
        // through the file rather than reading the pipe directly.
        p.arguments = ["-c", "'\(scriptURL.path)' >> '\(log.path)' 2>&1"]
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.processDidExit() }
        }

        do {
            try p.run()
        } catch {
            appendLog("Could not start the installer: \(error.localizedDescription)")
            markAllFailed()
            return
        }

        process = p
        isRunning = true
        startTailing(log)
    }

    /// Pausing takes effect once the item in flight finishes, so a download,
    /// copy or installer is never interrupted midway.
    func pause() {
        guard isRunning, !isPaused, let pause = pauseURL else { return }
        FileManager.default.createFile(atPath: pause.path, contents: nil)
        isPaused = true
        appendLog("Pause requested — will hold after the current item finishes.")
    }

    func resume() {
        guard let pause = pauseURL else { return }
        try? FileManager.default.removeItem(at: pause)
        isPaused = false
        appendLog("Resumed.")
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Removes apps. Kept separate from `run` so an uninstall can never be
    /// triggered by the ordinary install path.
    func runUninstall(targets: [UninstallTarget], options: ScriptOptions = ScriptOptions()) {
        guard !isRunning, !targets.isEmpty else { return }
        items = targets.map {
            QueueItem(id: $0.id, name: $0.name,
                      subtitle: $0.kind == "brew" ? "Homebrew" : ($0.kind == "pkg" ? "Package" : "Application"))
        }
        rawLog = ""; finished = false; summary = nil
        readOffset = 0; partial = ""; showAuthNotice = false

        let dir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString.prefix(8)
        let scriptURL = dir.appendingPathComponent("macsetup-uninstall-\(stamp).sh")
        let log = dir.appendingPathComponent("macsetup-uninstall-\(stamp).log")
        let pause = dir.appendingPathComponent("macsetup-uninstall-\(stamp).pause")
        logURL = log; pauseURL = pause
        try? FileManager.default.removeItem(at: pause)
        isPaused = false

        var opts = options
        opts.logPath = log.path
        opts.pausePath = pause.path
        let script = ScriptGenerator.buildUninstall(targets: targets, options: opts)

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            appendLog("Could not stage the uninstall script: \(error.localizedDescription)")
            markAllFailed(); return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "'\(scriptURL.path)' >> '\(log.path)' 2>&1"]
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.processDidExit() } }
        do { try p.run() } catch {
            appendLog("Could not start the uninstaller: \(error.localizedDescription)")
            markAllFailed(); return
        }
        process = p
        isRunning = true
        startTailing(log)
    }

    /// Installs Apple updates through the same queue, log and prompt as apps.
    /// Filters out anything `softwareupdate` cannot install unattended, saying
    /// why. Shared by both entry points so neither can drift into attempting it.
    static func withoutSystemReleases(_ updates: [SystemUpdate],
                                      log: (String) -> Void) -> [SystemUpdate] {
        let refused = updates.filter(\.isSystemRelease)
        for r in refused {
            log("\(r.title) has to be installed from Software Update — macOS needs a volume "
                + "owner's password for a system release, which cannot be supplied by a script. "
                + "Nothing was downloaded.")
        }
        return updates.filter { !$0.isSystemRelease }
    }

    func runSystemUpdates(_ updates: [SystemUpdate], options: ScriptOptions = ScriptOptions()) {
        guard !isRunning else { return }
        let refusedCount = updates.filter(\.isSystemRelease).count
        let updates = Self.withoutSystemReleases(updates, log: { appendLog($0) })
        guard !updates.isEmpty else {
            finished = true
            summary = (ok: 0, failed: 0, skipped: refusedCount)
            return
        }
        items = updates.map {
            QueueItem(id: $0.label, name: $0.title,
                      subtitle: "\($0.version) · \($0.sizeText)" + ($0.requiresRestart ? " · needs a restart" : ""))
        }
        rawLog = ""; finished = false; summary = nil
        readOffset = 0; partial = ""; showAuthNotice = true

        let dir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString.prefix(8)
        let scriptURL = dir.appendingPathComponent("macsetup-apple-\(stamp).sh")
        let log = dir.appendingPathComponent("macsetup-apple-\(stamp).log")
        let pause = dir.appendingPathComponent("macsetup-apple-\(stamp).pause")
        logURL = log; pauseURL = pause
        try? FileManager.default.removeItem(at: pause)
        isPaused = false

        var opts = options
        opts.logPath = log.path
        opts.pausePath = pause.path
        let script = ScriptGenerator.buildSystemUpdates(updates, options: opts)

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            appendLog("Could not stage the update script: \(error.localizedDescription)")
            markAllFailed(); return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "'\(scriptURL.path)' >> '\(log.path)' 2>&1"]
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.processDidExit() } }
        do { try p.run() } catch {
            appendLog("Could not start the updater: \(error.localizedDescription)")
            markAllFailed(); return
        }
        process = p
        isRunning = true
        startTailing(log)
    }

    func cancel() {
        // A paused script is sitting in a wait loop; clear the flag so it can
        // notice the termination rather than spinning.
        if let pause = pauseURL { try? FileManager.default.removeItem(at: pause) }
        isPaused = false
        process?.terminate()
        for idx in items.indices where !items[idx].state.isTerminal {
            items[idx].state = .failed
            items[idx].detail = "Cancelled"
        }
        stop()
    }

    // MARK: Log tailing

    private func startTailing(_ url: URL) {
        tailTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.drain(url)
                try? await Task.sleep(nanoseconds: 120_000_000)
                if self?.isRunning == false { break }
            }
            self?.drain(url)   // final flush after the process exits
        }
    }

    private func drain(_ url: URL) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: readOffset)
            guard let data = try fh.readToEnd(), !data.isEmpty else { return }
            readOffset += UInt64(data.count)
            let text = partial + (String(data: data, encoding: .utf8) ?? "")
            var lines = text.components(separatedBy: "\n")
            partial = lines.removeLast()          // keep any incomplete trailing line
            for line in lines { handle(line) }
        } catch {
            return
        }
    }

    private func handle(_ line: String) {
        guard line.hasPrefix("@@MS|") else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { appendLog(line) }
            return
        }
        let parts = line.dropFirst(5).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return }
        let id = String(parts[0])
        let state = String(parts[1])
        let detail = parts.count > 2 ? String(parts[2]) : ""

        if id == "__queue__" {
            switch state {
            case "auth":
                showAuthNotice = true
                appendLog("Requesting administrator authorisation for \(detail) package(s)…")
            case "paused":
                isPaused = true
            case "resumed":
                isPaused = false
            case "finished":
                let n = detail.split(separator: "|").map { Int($0) ?? 0 }
                if n.count == 3 { summary = (n[0], n[1], n[2]) }
            default: break
            }
            return
        }

        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }

        switch state {
        case "running":      items[idx].state = .running
        case "resolving":    items[idx].state = .resolving
        case "downloading":
            // detail is "<pct>" or "<pct>|<human readable size>"
            let parts = detail.split(separator: "|", maxSplits: 1)
            let pct = Int(parts.first.map(String.init) ?? "") ?? -1
            items[idx].state = .downloading(pct)
            if parts.count > 1 { items[idx].detail = String(parts[1]) }
        case "verifying":
            items[idx].state = .verifying
            if !detail.isEmpty { items[idx].signature = detail }
        case "installing":   items[idx].state = .installing
        case "awaitingauth": items[idx].state = .awaitingAuth
        case "retry":
            items[idx].state = .running
            items[idx].detail = detail
        case "auth":
            items[idx].state = .awaitingAuth
            items[idx].detail = detail
        case "done":
            items[idx].state = .done
            items[idx].detail = detail
        case "failed":
            items[idx].state = .failed
            items[idx].detail = detail.isEmpty ? "Failed" : detail
        case "skipped":
            items[idx].state = .skipped
            items[idx].detail = detail
        default: break
        }

        if !detail.isEmpty, state != "downloading" {
            appendLog("[\(items[idx].name)] \(detail)")
        }
    }

    private func appendLog(_ s: String) {
        rawLog += s + "\n"
        if rawLog.count > 400_000 { rawLog = String(rawLog.suffix(200_000)) }
    }

    private func markAllFailed() {
        for i in items.indices where !items[i].state.isTerminal { items[i].state = .failed }
        finished = true
    }

    private func processDidExit() {
        // Anything still mid-flight when bash exits did not complete.
        for i in items.indices where !items[i].state.isTerminal {
            items[i].state = .failed
            if items[i].detail.isEmpty { items[i].detail = "Did not complete" }
        }
        stop()
    }

    private func stop() {
        if let pause = pauseURL { try? FileManager.default.removeItem(at: pause) }
        isPaused = false
        isRunning = false
        finished = true
        showAuthNotice = false
        tailTask?.cancel()
        tailTask = nil
        process = nil
    }
}
