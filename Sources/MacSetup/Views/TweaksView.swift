import SwiftUI

struct TweaksView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("macOS System Tweaks")
                        .font(.system(size: 17, weight: .semibold))
                    Text("The `defaults` settings most admins apply to a new machine. Each one is written into the same script as your apps, and every tweak here is reversible.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Select recommended") { state.selectRecommendedTweaks() }
                        Button("Clear tweaks") { state.selectedTweaks.removeAll() }
                            .disabled(state.selectedTweaks.isEmpty)
                    }
                    .font(.system(size: 12))
                    .padding(.top, 3)
                }

                ForEach(state.tweaksByGroup, id: \.group) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section.group)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(section.tweaks) { tweak in
                            TweakRow(tweak: tweak)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TweakRow: View {
    @EnvironmentObject var state: AppState
    let tweak: DefaultTweak
    @State private var showCommand = false

    private var on: Bool { state.selectedTweaks.contains(tweak.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Button { state.toggle(tweak) } label: {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.55))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tweak.name).font(.system(size: 12.5, weight: .medium))
                        if tweak.recommended {
                            Text("recommended")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(tweak.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button { showCommand.toggle() } label: {
                    Image(systemName: showCommand ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the exact command")
            }

            if showCommand {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tweak.command)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    Text("Revert with:  \(tweak.revert)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                .padding(.leading, 25)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(on ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Selection review

struct SelectionReview: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review Selection")
                    .font(.system(size: 17, weight: .semibold))

                if !state.hasSelection {
                    Text("Nothing selected. Pick apps from the catalogue, or apply a saved profile from the sidebar.")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                } else {
                    Options()

                    let terminalOnly = state.selectedAppObjects.filter(\.needsTerminal)
                    if !terminalOnly.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(terminalOnly.count) app\(terminalOnly.count == 1 ? "" : "s") must be installed from Terminal",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                            Text("\(terminalOnly.map(\.name).sorted().joined(separator: ", ")) install through Homebrew as a .pkg, and Homebrew needs a terminal to ask for your password. Use Preview Script → Save as .sh and run it in Terminal. Everything else in this selection works from here.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                    }

                    if !state.selectedAppObjects.isEmpty {
                        Text("Applications (\(state.selectedAppObjects.count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        ForEach(state.selectedAppObjects) { app in
                            HStack(spacing: 9) {
                                Button { state.toggle(app) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                                }.buttonStyle(.plain)
                                AppIconView(app: app, side: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.system(size: 12.5, weight: .medium))
                                    Text(app.source.shortLabel)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.needsRoot {
                                    Label("admin", systemImage: "lock.fill")
                                        .font(.system(size: 10)).foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }

                    if !state.selectedWebAppObjects.isEmpty {
                        Text("Web Apps (\(state.selectedWebAppObjects.count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        if let b = state.browser {
                            Text(b.supportsAppMode
                                 ? "Each opens in its own \(b.name) window."
                                 : "\(b.name) has no app mode, so these open as ordinary windows.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        ForEach(state.selectedWebAppObjects) { web in
                            HStack(spacing: 9) {
                                Button { state.toggle(web) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                                }.buttonStyle(.plain)
                                WebIconView(web: web, side: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(web.name).font(.system(size: 12.5, weight: .medium))
                                    Text(web.url)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if web.isCustom {
                                    Text("custom").font(.system(size: 10))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.13), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }

                    if !state.selectedTweakObjects.isEmpty {
                        Text("System Tweaks (\(state.selectedTweakObjects.count))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        ForEach(state.selectedTweakObjects) { t in
                            HStack(spacing: 9) {
                                Button { state.toggle(t) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                                }.buttonStyle(.plain)
                                Text(t.name).font(.system(size: 12.5))
                                Spacer()
                                Text(t.group).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Options: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var icons: IconProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Run Options")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)

            Toggle("Verify code signature and Team ID before installing", isOn: $state.options.verifySignatures)
            Toggle("Abort an app if its signature does not check out", isOn: $state.options.strictVerify)
                .disabled(!state.options.verifySignatures)
                .padding(.leading, 18)
            Toggle("Skip apps that are already installed", isOn: $state.options.skipInstalled)
            Toggle("Install into ~/Applications instead of /Applications", isOn: $state.options.installToUserApplications)
            Divider().padding(.vertical, 2)
            Toggle("Show an icon in the menu bar", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "showMenuBarItem") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "showMenuBarItem") }))
                .help("Shows the update count next to the clock")
            Toggle("Keep running in the menu bar when the window is closed", isOn: Binding(
                get: { UserDefaults.standard.object(forKey: "liveInMenuBar") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "liveInMenuBar") }))
                .help("Closing the window hides the Dock icon and leaves the menu bar item running")
            Divider().padding(.vertical, 2)
            Toggle("Load app icons from vendor websites", isOn: Binding(
                get: { icons.allowRemote },
                set: { icons.allowRemote = $0 }))
                .help("Off: icons come only from apps already installed, plus generated tiles")
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
