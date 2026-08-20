import SwiftUI

struct CatalogView: View {
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 460), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider()
            if state.filteredApps.isEmpty {
                EmptyResults()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(state.filteredApps) { app in
                            AppCard(app: app)
                        }
                    }
                    .padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps, vendors, descriptions…", text: $state.search)
                    .textFieldStyle(.plain)
                if !state.search.isEmpty {
                    Button { state.search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }

                Divider().frame(height: 16)

                Menu {
                    Picker("Sort by", selection: $state.sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Toggle("Hide apps already installed", isOn: $state.hideInstalled)
                    Toggle("Hide apps needing an admin password", isOn: $state.hideAdminRequired)
                    Divider()
                    Section("License") {
                        ForEach(state.allLicenses, id: \.self) { lic in
                            Toggle(lic.capitalized, isOn: binding(for: lic, in: \.licenseFilter))
                        }
                    }
                    Section("Source") {
                        ForEach([SourceKind.direct, .github, .brew, .script], id: \.self) { kind in
                            Toggle(sourceName(kind), isOn: sourceBinding(kind))
                        }
                    }
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if state.filtersActive {
                    Button("Reset") { state.resetFilters() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }

            HStack(spacing: 6) {
                ForEach(state.allTags, id: \.self) { tag in
                    TagChip(tag: tag, active: state.activeTags.contains(tag)) {
                        if state.activeTags.contains(tag) { state.activeTags.remove(tag) }
                        else { state.activeTags.insert(tag) }
                    }
                }
                Spacer()
                Text("\(state.filteredApps.count) of \(state.allApps.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Select All") { state.selectAllVisible() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                Button("None") { state.deselectAllVisible() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func binding(for value: String, in keyPath: ReferenceWritableKeyPath<AppState, Set<String>>) -> Binding<Bool> {
        Binding(
            get: { state[keyPath: keyPath].contains(value) },
            set: { on in
                if on { state[keyPath: keyPath].insert(value) }
                else { state[keyPath: keyPath].remove(value) }
            }
        )
    }

    private func sourceBinding(_ kind: SourceKind) -> Binding<Bool> {
        Binding(
            get: { state.sourceFilter.contains(kind) },
            set: { on in
                if on { state.sourceFilter.insert(kind) } else { state.sourceFilter.remove(kind) }
            }
        )
    }

    private func sourceName(_ k: SourceKind) -> String {
        switch k {
        case .direct: return "Direct from vendor"
        case .github: return "GitHub release"
        case .brew:   return "Homebrew"
        case .script: return "Vendor script"
        }
    }
}

struct TagChip: View {
    let tag: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(active ? Color.accentColor : Color.secondary.opacity(0.14),
                            in: Capsule())
                .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App card

struct AppCard: View {
    @EnvironmentObject var state: AppState
    let app: CatalogApp

    private var selected: Bool { state.selectedApps.contains(app.id) }
    private var installed: Bool { state.isInstalled(app) }

    var body: some View {
        Button { state.toggle(app) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))

                    IconView(target: state.iconTarget(for: app), side: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        Text(app.vendor)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if installed {
                        Text("Installed")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }

                Text(app.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    SourceBadge(source: app.source)
                    if app.needsRoot {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("Installing this package needs your admin password")
                    }
                    Spacer()
                    ForEach(app.tags.prefix(2), id: \.self) { t in
                        Text(t)
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18),
                                  lineWidth: selected ? 1.4 : 1)
            )
        }
        .buttonStyle(.plain)
        // Attaching a context menu to all 162 cards makes scrolling stutter on
        // macOS, so the same action is a double-click.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let u = URL(string: app.homepage) { NSWorkspace.shared.open(u) }
        })
    }
}

struct SourceBadge: View {
    let source: AppSource

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5))
            Text(text).font(.system(size: 9.5, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
        .help(source.shortLabel)
    }

    private var symbol: String {
        switch source.kind {
        case .direct: return "arrow.down.to.line"
        case .github: return "shippingbox"
        case .brew:   return "mug"
        case .script: return "terminal"
        }
    }
    private var text: String {
        switch source.kind {
        case .direct: return "Vendor"
        case .github: return "GitHub"
        case .brew:   return "Homebrew"
        case .script: return "Script"
        }
    }
    private var color: Color {
        switch source.kind {
        case .direct: return .blue
        case .github: return .purple
        case .brew:   return .orange
        case .script: return .teal
        }
    }
}

struct EmptyResults: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Nothing matches these filters")
                .font(.system(size: 14, weight: .medium))
            Button("Reset filters") { state.resetFilters() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
