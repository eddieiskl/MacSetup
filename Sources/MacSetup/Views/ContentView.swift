import SwiftUI

enum Pane: Hashable {
    case all
    case category(String)
    case webApps
    case installed
    case updates
    case tweaks
    case selection
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var engine: InstallEngine
    @EnvironmentObject var metrics: WindowMetrics
    @EnvironmentObject var system: SystemUpdateChecker

    @State private var pane: Pane? = .all
    @State private var showScript = false
    @State private var showQueue = false
    @State private var showSaveProfile = false

    var body: some View {
        Group {
            if let error = state.loadError {
                CatalogFailure(message: error)
            } else {
                // GeometryReader reports the size the window actually proposes,
                // and pinning the split view to it stops SwiftUI laying the
                // content out at its own (much larger) ideal height. Without
                // this the panes and the sidebar were drawn taller than the
                // window and clipped at both ends, so their headers and footers
                // could not be reached at all.
                NavigationSplitView {
                    SidebarView(pane: paneSelection, showSaveProfile: $showSaveProfile)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 235, max: 320)
                } detail: {
                    detail
                }
                // Exactly the window's content area, measured from AppKit.
                .frame(width: metrics.contentSize.width > 0 ? metrics.contentSize.width : nil,
                       height: metrics.contentSize.height > 0 ? metrics.contentSize.height : nil)
            }
        }
        .sheet(isPresented: $showScript) { ScriptSheet(script: state.buildScript()) }
        .sheet(isPresented: $showQueue) { QueueSheet() }
        .sheet(isPresented: $showSaveProfile) { SaveProfileSheet() }
    }

    /// Selection and the catalogue filter must move together. Applying the
    /// filter as a side effect (onChange, or task) let the two drift apart —
    /// the sidebar highlighted one category while the grid showed another.
    /// Writing both in the binding makes that impossible.
    private var paneSelection: Binding<Pane?> {
        Binding(
            get: { pane },
            set: { newValue in
                pane = newValue
                switch newValue {
                case .all:              state.category = nil
                case .category(let id): state.category = id
                case .none:             state.category = nil
                default:                break
                }
            }
        )
    }

    private var detail: some View {
        Group {
            switch pane {
            case .webApps:
                WebAppsView()
            case .installed:
                InstalledView()
            case .updates:
                UpdatesView()
            case .tweaks:
                TweaksView()
            case .selection:
                SelectionReview()
            default:
                CatalogView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if pane != .installed {
                    Divider()
                    ActionBar(showScript: $showScript, showQueue: $showQueue)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.contentSize.height > 0 ? metrics.contentSize.height : nil,
               alignment: .top)

    }
}

// MARK: - Bottom action bar

struct ActionBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var system: SystemUpdateChecker
    @EnvironmentObject var engine: InstallEngine
    @Binding var showScript: Bool
    @Binding var showQueue: Bool

    private var appCount: Int { state.selectedApps.count }
    private var tweakCount: Int { state.selectedTweaks.count }
    private var webCount: Int { state.selectedWebApps.count }
    private var systemCount: Int { state.selectedSystemUpdates.count }
    private var total: Int { appCount + tweakCount + webCount + systemCount }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summaryLine)
                    .font(.system(size: 13, weight: .medium))
                if state.hasSelection {
                    Text(detailLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if state.hasSelection {
                Button("Clear") { state.clearSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button {
                showScript = true
            } label: {
                Label("Preview Script", systemImage: "doc.plaintext")
            }
            .disabled(!state.hasSelection)
            .help("Read or export the bash script this selection produces, without running it")

            Button {
                engine.run(apps: state.selectedAppObjects,
                           tweaks: state.selectedTweakObjects,
                           webApps: state.selectedWebAppObjects,
                           systemUpdates: system.updates.filter {
                               state.selectedSystemUpdates.contains($0.label)
                           },
                           browser: state.browser,
                           options: state.options)
                showQueue = true
            } label: {
                Label("Install \(total) Item\(total == 1 ? "" : "s")",
                      systemImage: "arrow.down.circle.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!state.hasSelection || engine.isRunning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var summaryLine: String {
        if !state.hasSelection { return "Nothing selected yet" }
        var bits: [String] = []
        if appCount > 0 { bits.append("\(appCount) app\(appCount == 1 ? "" : "s")") }
        if webCount > 0 { bits.append("\(webCount) web app\(webCount == 1 ? "" : "s")") }
        if systemCount > 0 { bits.append("\(systemCount) Apple update\(systemCount == 1 ? "" : "s")") }
        if tweakCount > 0 { bits.append("\(tweakCount) tweak\(tweakCount == 1 ? "" : "s")") }
        return bits.joined(separator: " · ") + " selected"
    }

    private var detailLine: String {
        let pkgs = state.selectedAppObjects.filter(\.needsRoot).count
        var bits: [String] = ["Targeting \(state.arch.display)"]

        // Describe what actually needs authorising, Apple updates included.
        var privileged: [String] = []
        if pkgs > 0 { privileged.append("\(pkgs) package\(pkgs == 1 ? "" : "s")") }
        if systemCount > 0 { privileged.append("\(systemCount) Apple update\(systemCount == 1 ? "" : "s")") }

        switch state.authPromptCount {
        case 0:
            bits.append("no password needed")
        case 1 where !privileged.isEmpty:
            bits.append("1 password prompt for " + privileged.joined(separator: " and "))
        case 1:
            bits.append("1 password prompt to install Homebrew")
        default:
            let what = privileged.isEmpty ? "the rest" : privileged.joined(separator: " and ")
            bits.append("2 password prompts (Homebrew, then \(what))")
        }
        if webCount > 0, let b = state.browser { bits.append("Web apps open in \(b.name)") }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Load failure

struct CatalogFailure: View {
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("The app catalogue could not be loaded")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
        }
        .padding(40)
    }
}
