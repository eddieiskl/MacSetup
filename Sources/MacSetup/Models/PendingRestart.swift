import Foundation

/// An Apple update that has been downloaded but not installed, because
/// installing it would restart the Mac.
struct StagedUpdate: Codable, Identifiable, Hashable {
    let label: String
    let title: String
    let version: String
    let stagedAt: Date
    var id: String { label }
}

/// Remembers updates staged overnight so they can be offered at a moment the
/// user is actually present — the next unlock — rather than rebooting the Mac
/// while nobody is watching.
@MainActor
final class PendingRestartStore: ObservableObject {

    @Published private(set) var staged: [StagedUpdate] = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSetup", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("staged-updates.json")
    }()

    init() { load() }

    func load() {
        guard let d = try? Data(contentsOf: url) else { staged = []; return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        staged = (try? dec.decode([StagedUpdate].self, from: d)) ?? []
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(staged) { try? d.write(to: url, options: .atomic) }
    }

    /// Only true once softwareupdate reports the download finished. A staged
    /// entry promises "already downloaded, installing is quick" — if that is
    /// not actually true, the button starts a multi-gigabyte download the user
    /// did not expect.
    func record(_ updates: [SystemUpdate], verified: Bool = true) {
        guard verified else { return }
        recordVerified(updates)
    }

    private func recordVerified(_ updates: [SystemUpdate]) {
        for u in updates where !staged.contains(where: { $0.label == u.label }) {
            staged.append(StagedUpdate(label: u.label, title: u.title,
                                       version: u.version, stagedAt: Date()))
        }
        persist()
    }

    func clear(_ labels: [String]) {
        staged.removeAll { labels.contains($0.label) }
        persist()
    }

    /// Drop anything Apple no longer offers — it was installed another way, or
    /// superseded. Otherwise the prompt would nag about a phantom update.
    func reconcile(with available: [SystemUpdate]) {
        let live = Set(available.map(\.label))
        let before = staged.count
        staged.removeAll { !live.contains($0.label) }
        if staged.count != before { persist() }
    }
}
