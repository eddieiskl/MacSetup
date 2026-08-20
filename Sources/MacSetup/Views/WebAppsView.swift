import SwiftUI

struct WebAppsView: View {
    @EnvironmentObject var state: AppState
    @State private var newName = ""
    @State private var newURL = ""
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerBlock
                modePicker
                if !state.options.standaloneWebApps { browserPicker }
                customBlock

                ForEach(groups, id: \.group) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(section.group)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary).textCase(.uppercase)
                            Spacer()
                            Button("All") {
                                state.selectedWebApps.formUnion(section.apps.map(\.id))
                            }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 215, maximum: 340), spacing: 9)],
                                  spacing: 9) {
                            ForEach(section.apps) { WebAppCard(web: $0) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groups: [(group: String, apps: [WebApp])] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return state.webAppsByGroup }
        return state.webAppsByGroup.compactMap { g in
            let hits = g.apps.filter {
                $0.name.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
            }
            return hits.isEmpty ? nil : (g.group, hits)
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Web Apps")
                .font(.system(size: 17, weight: .semibold))
            Text("Installs a site as its own app with a Dock icon and a Spotlight entry, opening in a dedicated window instead of another browser tab. Useful for Google Workspace, admin consoles and internal tools that have no native client.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter web apps…", text: $search).textFieldStyle(.plain)
                Spacer()
                if !state.selectedWebApps.isEmpty {
                    Text("\(state.selectedWebApps.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Clear") { state.selectedWebApps.removeAll() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                }
            }
            .padding(.top, 4)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("How web apps behave")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)

            Picker("", selection: $state.options.standaloneWebApps) {
                Text("Open in browser").tag(false)
                Text("Standalone app").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if state.options.standaloneWebApps {
                Label("A real application: its own Dock icon, window and Cmd-Tab entry. It keeps a separate sign-in from your browser, and Google blocks sign-in from embedded windows — so use browser mode for Gmail, Calendar and Drive.",
                      systemImage: "macwindow")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Hands the site to your browser, so you stay signed in to Google and Microsoft. The bundle exits once the browser takes over, so it does not stay in the Dock while open.",
                      systemImage: "safari")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var browserPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Open web apps in")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)

            if state.browsers.isEmpty {
                Text("No supported browser found.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { state.browser?.bundleID ?? "" },
                    set: { id in state.browser = state.browsers.first { $0.bundleID == id } }
                )) {
                    ForEach(state.browsers) { b in
                        Text(b.supportsAppMode ? b.name : "\(b.name) — no app mode").tag(b.bundleID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                if let b = state.browser {
                    Label(b.supportsAppMode
                          ? "\(b.name) supports app mode, so each site gets a real standalone window."
                          : "\(b.name) has no app-mode flag, so these open as ordinary windows. Chrome, Edge, Brave or Vivaldi give a proper standalone window.",
                          systemImage: b.supportsAppMode ? "checkmark.circle" : "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(b.supportsAppMode ? .green : .orange)
                }
                Text("Web apps use the browser's normal profile, so you stay signed in to Google and Microsoft.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var customBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Add your own")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            HStack(spacing: 8) {
                TextField("Name, e.g. Intranet", text: $newName)
                    .textFieldStyle(.roundedBorder).frame(width: 170)
                TextField("https://…", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    state.addCustomWebApp(name: newName, url: newURL)
                    newName = ""; newURL = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Custom entries are saved locally and travel inside any profile you export.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct WebAppCard: View {
    @EnvironmentObject var state: AppState
    let web: WebApp

    private var selected: Bool { state.selectedWebApps.contains(web.id) }

    var body: some View {
        Button { state.toggle(web) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                WebIconView(web: web, side: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(web.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(web.host).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if web.isCustom {
                    Button {
                        state.removeCustomWebApp(web)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this custom web app")
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16),
                              lineWidth: selected ? 1.3 : 1))
        }
        .buttonStyle(.plain)
        .help(web.summary)
        .contextMenu {
            Button("Open in browser") {
                if let u = URL(string: web.url) { NSWorkspace.shared.open(u) }
            }
        }
    }
}
