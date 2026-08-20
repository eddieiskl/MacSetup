import SwiftUI
import AppKit

/// Renders the interface offscreen to PNG files.
///
/// Screen capture needs a permission that a headless run does not have, so the
/// UI could never actually be looked at. ImageRenderer draws the same views into
/// a bitmap without a window or any permission, which makes the layout
/// verifiable rather than merely "it compiled".
@MainActor
enum UIRenderer {

    static func renderAll(to directory: URL, state: AppState,
                          icons: IconProvider, profiles: ProfileStore,
                          engine: InstallEngine, checker: UpdateChecker) -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []

        func shot<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ build: () -> V) {
            let wrapped = build()
                .environmentObject(state)
                .environmentObject(icons)
                .environmentObject(profiles)
                .environmentObject(engine)
                .environmentObject(checker)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))

            let renderer = ImageRenderer(content: wrapped)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            let url = directory.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            written.append(url.path)
        }

        // ImageRenderer never lays out lazy containers, and AppKit-backed
        // controls (TextField, Menu, Picker) come out as placeholders. So the
        // components are rendered directly, in plain stacks, which is what
        // actually needs checking: card layout, badges, states and spacing.
        let sample = ["google-chrome", "microsoft-word", "tailscale", "claude",
                      "visual-studio-code", "nordvpn"]
            .compactMap { id in state.allApps.first { $0.id == id } }

        shot("01-app-cards", CGSize(width: 940, height: 260)) {
            VStack(alignment: .leading, spacing: 12) {
                Text("App cards — selected, unselected, installed, needs admin")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(sample.prefix(3)) { AppCard(app: $0) }
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(sample.dropFirst(3).prefix(3)) { AppCard(app: $0) }
                }
            }
            .padding(16)
        }

        let webs = ["gmail", "google-calendar", "notion-web", "azure-portal"]
            .compactMap { id in state.allWebApps.first { $0.id == id } }
        shot("02-web-app-cards", CGSize(width: 940, height: 150)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Web app cards").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 10) { ForEach(webs) { WebAppCard(web: $0) } }
            }
            .padding(16)
        }

        let tweaks = Array((state.catalog?.systemDefaults ?? []).prefix(4))
        shot("03-tweaks", CGSize(width: 780, height: 260)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("System tweaks").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(tweaks) { TweakRow(tweak: $0) }
            }
            .padding(16)
        }

        // Every queue state at once, which is the part with the most moving parts.
        // ids must be catalogue ids — the queue resolves the icon from them.
        let states: [(id: String, name: String, state: ItemState, detail: String)] = [
            ("google-chrome", "Google Chrome", .downloading(62), "3.4 MB of 5.5 MB"),
            ("slack", "Slack", .verifying, "Team ID BQR82RBBHL"),
            ("microsoft-word", "Microsoft Word", .awaitingAuth, "Waiting for administrator authorisation"),
            ("visual-studio-code", "Visual Studio Code", .installing, "Copying Visual Studio Code.app"),
            ("rectangle", "Rectangle", .done, "Installed"),
            ("tailscale", "Tailscale", .failed, "Needs a terminal for its password prompt"),
            ("firefox", "Mozilla Firefox", .skipped, "Already installed"),
            ("jq", "jq", .pending, ""),
        ]
        shot("04-queue-states", CGSize(width: 620, height: 400)) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Install queue — every state")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(Array(states.enumerated()), id: \.offset) { _, s in
                    QueueRow(item: QueueItem(id: s.id, name: s.name,
                                             subtitle: "Direct from vendor",
                                             state: s.state, detail: s.detail))
                }
            }
            .padding(14)
        }

        // Installed rows: catalogue app, Homebrew app, package, and one the
        // catalogue does not know about.
        let installedSample: [InstalledEntry] = [
            InstalledEntry(id: "/Applications/Google Chrome.app", name: "Google Chrome",
                           bundleID: "com.google.Chrome", version: "151.0.7922.140",
                           path: "/Applications/Google Chrome.app", catalogID: "google-chrome"),
            InstalledEntry(id: "/Applications/Blender.app", name: "Blender",
                           bundleID: "org.blenderfoundation.blender", version: "4.2.0",
                           path: "/Applications/Blender.app", catalogID: "blender"),
            InstalledEntry(id: "/Applications/Microsoft Word.app", name: "Microsoft Word",
                           bundleID: "com.microsoft.Word", version: "16.112.1",
                           path: "/Applications/Microsoft Word.app", catalogID: "microsoft-word"),
            InstalledEntry(id: "/Applications/Some Internal Tool.app", name: "Some Internal Tool",
                           bundleID: "com.example.internal", version: "2.1",
                           path: "/Applications/Some Internal Tool.app", catalogID: nil),
        ]
        shot("07-installed-rows", CGSize(width: 780, height: 220)) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Installed — catalogue, Homebrew, package, and unknown")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(installedSample) { InstalledRowPreview(entry: $0, selected: $0.name == "Blender") }
            }
            .padding(14)
        }

        shot("08-installed-pane", CGSize(width: 900, height: 500)) { InstalledView() }

        shot("05-action-bar", CGSize(width: 940, height: 70)) {
            ActionBar(showScript: .constant(false), showQueue: .constant(false))
        }

        let updates: [UpdateResult] = [
            UpdateResult(id: "blender", name: "Blender",
                         state: .available(installed: "4.2.0", latest: "5.2.0"), via: "Homebrew"),
            UpdateResult(id: "zoom", name: "Zoom", state: .upToDate("7.1.5 (84650)"), via: "vendor download"),
            UpdateResult(id: "google-chrome", name: "Google Chrome",
                         state: .unknown(installed: "151.0", reason: "updates itself via Google Keystone"),
                         via: "self-updating"),
        ]
        shot("06-update-rows", CGSize(width: 700, height: 170)) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Updates — available, current, self-updating")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(updates) { r in UpdateRowPreview(result: r) }
            }
            .padding(14)
        }

        return written
    }
}

/// Standalone copy of an Installed row, for the same reason as below.
struct InstalledRowPreview: View {
    @EnvironmentObject var state: AppState
    let entry: InstalledEntry
    let selected: Bool

    var body: some View {
        let app = entry.catalogID.flatMap { id in state.allApps.first { $0.id == id } }
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
            if let app { AppIconView(app: app, side: 28) }
            else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: "app.dashed").font(.system(size: 13)).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12.5, weight: .medium))
                Text("\(entry.version)  ·  \(entry.bundleID)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            let label: (String, Color) = {
                guard let app else { return ("not in catalogue", .secondary) }
                if app.source.format == "pkg" { return ("package", .orange) }
                if app.source.kind == .brew { return ("homebrew", .orange) }
                return ("catalogue", .blue)
            }()
            Text(label.0)
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(label.1.opacity(0.15), in: Capsule())
                .foregroundStyle(label.1)
        }
        .padding(.vertical, 6).padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
    }
}

/// Standalone copy of an Updates row, so the renderer does not need the whole
/// pane (which is wrapped in a ScrollView that will not render offscreen).
struct UpdateRowPreview: View {
    @EnvironmentObject var state: AppState
    let result: UpdateResult

    var body: some View {
        HStack(spacing: 10) {
            if let app = state.allApps.first(where: { $0.id == result.id }) {
                AppIconView(app: app, side: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).font(.system(size: 12.5, weight: .medium))
                switch result.state {
                case .available(let i, let l):
                    HStack(spacing: 4) {
                        Text(i).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                        Text(l).foregroundStyle(.orange).fontWeight(.medium)
                        Text("· via \(result.via)").foregroundStyle(.tertiary)
                    }.font(.system(size: 10.5))
                case .upToDate(let v):
                    Text("\(v) · via \(result.via)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                case .unknown(let v, let why):
                    Text("\(v) · \(why)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if case .upToDate = result.state {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(result.state.isUpdate ? Color.orange.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
    }
}
