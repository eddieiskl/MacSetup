import Foundation

/// Reads every installed application bundle once, which is far faster and
/// more reliable than shelling out to mdfind per app. System applications are
/// skipped — they are not this tool's to remove.
///
/// Extracted out of the app's own state so the CLI, Desired State, Doctor and
/// a future MCP server all see exactly the same installed-app picture the
/// SwiftUI app does, rather than each re-implementing the scan.
public enum MachineInventory {

    public static func scan(catalogApps: [CatalogApp]) async -> [InstalledEntry] {
        let dirs = ["/Applications", "\(NSHomeDirectory())/Applications", "/Applications/Utilities"]
        struct Raw: Sendable { let name: String; let bundleID: String; let version: String; let path: String }

        let raw: [Raw] = await Task.detached(priority: .utility) {
            var out: [Raw] = []
            let fm = FileManager.default
            for dir in dirs {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasSuffix(".app") {
                    let path = "\(dir)/\(entry)"
                    let plist = "\(path)/Contents/Info.plist"
                    let d = NSDictionary(contentsOfFile: plist)
                    let bundle = (d?["CFBundleIdentifier"] as? String) ?? ""
                    let version = (d?["CFBundleShortVersionString"] as? String)
                        ?? (d?["CFBundleVersion"] as? String) ?? "—"
                    let name = String(entry.dropLast(4))
                    out.append(Raw(name: name, bundleID: bundle, version: version, path: path))
                }
            }
            return out
        }.value

        let byBundle = Dictionary(catalogApps.compactMap { app -> (String, String)? in
            guard let b = app.bundleId else { return nil }
            return (b, app.id)
        }, uniquingKeysWith: { a, _ in a })

        return raw.map { r in
            InstalledEntry(id: r.path, name: r.name, bundleID: r.bundleID,
                           version: r.version, path: r.path,
                           catalogID: byBundle[r.bundleID])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
