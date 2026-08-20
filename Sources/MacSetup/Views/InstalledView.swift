import SwiftUI

struct InstalledView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: InstallEngine
    @State private var selected: Set<String> = []
    @State private var showConfirm = false
    @State private var showQueue = false

    private var visible: [InstalledEntry] { state.visibleInstalled }
    private var chosen: [InstalledEntry] { visible.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if visible.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visible) { row($0) }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showConfirm) {
            UninstallSheet(targets: chosen.map { state.uninstallTarget(for: $0) },
                           names: chosen.map(\.name)) {
                showQueue = true
                selected.removeAll()
            }
        }
        .sheet(isPresented: $showQueue) { QueueSheet() }
        .task { if state.installedEntries.isEmpty { await state.scanInstalled() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Installed")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Everything in /Applications and ~/Applications. Select what you want removed — bundles are moved to the Trash, never deleted.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await state.scanInstalled() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter by name or bundle id…", text: $state.installedSearch)
                    .textFieldStyle(.plain)
                Toggle("Include apps not in the catalogue", isOn: $state.showNonCatalogueApps)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(state.installedSearch.isEmpty
                 ? "Nothing from the catalogue is installed yet"
                 : "Nothing matches that filter")
                .font(.system(size: 14, weight: .medium))
            if !state.showNonCatalogueApps {
                Button("Include apps not in the catalogue") { state.showNonCatalogueApps = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ e: InstalledEntry) -> some View {
        let app = e.catalogID.flatMap { state.app(id: $0) }
        let isSelected = selected.contains(e.id)
        Button {
            if isSelected { selected.remove(e.id) } else { selected.insert(e.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))

                if let app { AppIconView(app: app, side: 28) }
                else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 28, height: 28)
                        .overlay(Image(systemName: "app.dashed")
                            .font(.system(size: 13)).foregroundStyle(.secondary))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name).font(.system(size: 12.5, weight: .medium))
                    Text("\(e.version)  ·  \(e.bundleID.isEmpty ? "no bundle id" : e.bundleID)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)

                if let app {
                    if app.source.format == "pkg" {
                        badge("package", .orange).help("Installed from a package — use the vendor's uninstaller")
                    } else if app.source.kind == .brew {
                        badge("homebrew", .orange)
                    } else {
                        badge("catalogue", .blue)
                    }
                } else {
                    badge("not in catalogue", .secondary)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)])
            }
            Divider()
            Button("Move \(e.name) to Trash…", role: .destructive) {
                selected = [e.id]
                showConfirm = true
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var footer: some View {
        HStack {
            Text(selected.isEmpty
                 ? "\(visible.count) app\(visible.count == 1 ? "" : "s") · \(state.installedFromCatalogue) from the catalogue"
                 : "\(selected.count) selected")
                .font(.system(size: 12))
                .foregroundStyle(selected.isEmpty ? .secondary : .primary)
            Spacer()
            if !selected.isEmpty {
                Button("Clear") { selected.removeAll() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button("Select All") { selected = Set(visible.map(\.id)) }
                .buttonStyle(.plain).foregroundStyle(.tint)
            if selected.isEmpty {
                Text("Select apps to remove them")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Button {
                    showConfirm = true
                } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .disabled(true)
            } else {
                Button(role: .destructive) {
                    showConfirm = true
                } label: {
                    Label("Move \(selected.count) to Trash…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(engine.isRunning)
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
    }
}
