import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var checker: UpdateChecker
    @Binding var pane: Pane?
    @Binding var showSaveProfile: Bool

    @State private var importing = false
    @State private var exporting: Profile?
    @State private var importError: String?

    var body: some View {
        List(selection: $pane) {
            Section("Catalogue") {
                row(.all, "Everything", "square.grid.2x2", count: state.allApps.count)
                ForEach(state.categories) { c in
                    row(.category(c.id), c.name, c.symbol,
                        count: state.categoryCounts[c.id] ?? 0)
                }
            }

            Section("Setup") {
                row(.webApps, "Web Apps", "safari",
                    count: state.allWebApps.count)
                row(.installed, "Installed", "square.stack.3d.up",
                    count: state.installedFromCatalogue)
                updatesRow
                row(.tweaks, "System Tweaks", "slider.horizontal.3",
                    count: state.catalog?.systemDefaults.count ?? 0)
                row(.selection, "Review Selection", "checklist",
                    count: state.selectedApps.count + state.selectedTweaks.count + state.selectedWebApps.count,
                    highlight: state.hasSelection)
            }

            Section("Quick Picks") {
                quickPick("Essentials", "star.fill", tag: "essential")
                quickPick("Business Baseline", "briefcase.fill", tag: "business")
                quickPick("Free & Open Source", "heart.fill", tag: "open-source")
                Button {
                    state.selectRecommendedTweaks()
                } label: {
                    Label("Recommended Tweaks", systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain)
            }

            Section("Profiles") {
                if profiles.profiles.isEmpty {
                    Text("No saved profiles")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(profiles.profiles) { p in
                    ProfileRow(profile: p, exporting: $exporting)
                }
                HStack(spacing: 10) {
                    Button { showSaveProfile = true } label: {
                        Label("Save", systemImage: "plus.circle")
                    }
                    .disabled(!state.hasSelection)
                    Button { importing = true } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .listStyle(.sidebar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let p = try profiles.importProfile(from: url)
                let missing = state.unknownEntries(in: p)
                if !missing.isEmpty {
                    importError = "Imported, but \(missing.count) entr\(missing.count == 1 ? "y is" : "ies are") not in this catalogue: \(missing.prefix(6).joined(separator: ", "))"
                }
            } catch {
                importError = error.localizedDescription
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil },
                                           set: { if !$0 { exporting = nil } }),
                      document: exporting.map { ProfileDocument(profile: $0) },
                      contentType: .json,
                      defaultFilename: exporting?.name ?? "profile") { _ in exporting = nil }
        .alert("Profile", isPresented: Binding(get: { importError != nil },
                                               set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder
    private var updatesRow: some View {
        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            .badge(checker.updates.count)
            .fontWeight(checker.updates.isEmpty ? .regular : .semibold)
            .tag(Pane.updates)
    }

    private func row(_ p: Pane, _ title: String, _ symbol: String,
                     count: Int, highlight: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .badge(count)
            .fontWeight(highlight ? .semibold : .regular)
            .tag(p)
    }

    private func quickPick(_ title: String, _ symbol: String, tag: String) -> some View {
        Button {
            state.selectTag(tag)
        } label: {
            Label(title, systemImage: symbol)
                .badge(state.tagCounts[tag] ?? 0)
        }
        .buttonStyle(.plain)
        .help("Add every app tagged \(tag) to the selection")
    }
}

private struct ProfileRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var profiles: ProfileStore
    let profile: Profile
    @Binding var exporting: Profile?

    var body: some View {
        Button {
            state.apply(profile)
        } label: {
            HStack {
                Image(systemName: "person.crop.rectangle.stack")
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name).lineLimit(1)
                    Text("\(profile.appIDs.count) apps · \(profile.tweakIDs.count) tweaks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Apply") { state.apply(profile) }
            Button("Export…") { exporting = profile }
            Divider()
            Button("Delete", role: .destructive) { profiles.delete(profile) }
        }
    }
}

// MARK: - Export wrapper

struct ProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let profile: Profile

    init(profile: Profile) { self.profile = profile }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.profile = Profile(document: try dec.decode(Profile.Document.self, from: data))
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try enc.encode(profile.document))
    }
}
