import SwiftUI

struct UpdatesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var checker: UpdateChecker
    @EnvironmentObject var engine: InstallEngine
    @EnvironmentObject var schedule: UpdateSchedule
    @EnvironmentObject var system: SystemUpdateChecker
    @EnvironmentObject var store: AppStoreChecker
    @EnvironmentObject var staged: PendingRestartStore
    @AppStorage("unlockAction") private var unlockAction = UnlockAction.notify.rawValue
    @AppStorage("nagEnabled") private var nagEnabled = false
    @AppStorage("nagAfterDays") private var nagAfterDays = 7
    @AppStorage("nagDeadlineDays") private var nagDeadlineDays = 14
    @AppStorage("nagLateSnoozeMinutes") private var nagLateSnooze = 10
    @State private var loginAtStart = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var caching = false
    @State private var osDownloadMessage: String?

    /// Starts the installer download in Terminal, where Apple's own progress
    /// is shown. Nothing here supervises it — that guessing is what killed a
    /// download at 87%.
    private func startOSDownload(_ u: SystemUpdate) {
        let script = OSInstallerCache.fetchScript(version: u.version, sizeText: u.sizeText)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsetup-fetch-\(UUID().uuidString.prefix(8)).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
        } catch {
            osDownloadMessage = "Could not prepare the download."
            return
        }
        if !OSUpgrade.openInTerminal(url) {
            osDownloadMessage = "Could not open Terminal."
        }
    }
    @State private var cacheMessage: String?

    /// Runs the same fetch the command line does, so the two cannot drift.
    private func cacheInstaller() async {
        guard let release = system.updates.first(where: \.isSystemRelease) else { return }
        if let already = OSInstallerCache.cached(matching: release) {
            cacheMessage = "Already downloaded (\(already.sizeText))"; return
        }
        guard OSInstallerCache.hasRoomFor(sizeKiB: release.sizeKiB) else {
            cacheMessage = "Not enough free space for \(release.sizeText)"; return
        }
        caching = true
        cacheMessage = "Downloading \(release.sizeText) in the background…"
        let args = OSInstallerCache.fetchArguments(version: release.version)
        let done: Bool = await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
            p.arguments = args
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }.value
        caching = false
        if let got = OSInstallerCache.cached(matching: release) {
            cacheMessage = "Ready — \(got.sizeText) downloaded"
        } else {
            cacheMessage = done ? "Finished, but no installer appeared in /Applications"
                                : "The download did not complete"
        }
    }

    /// Spelled out because the three options behave very differently, and the
    /// macOS-release caveat is not something anyone would guess.
    private var unlockExplanation: String {
        switch UnlockAction(rawValue: unlockAction) ?? .notify {
        case .notify:
            return "Anything downloaded overnight waits until you choose to install it."
        case .install:
            return "Updates MacSetup staged overnight are installed as soon as you come back, "
                 + "asking for your password once. A full macOS release is only mentioned — "
                 + "it cannot be installed this way."
        case .installAndOpenSettings:
            return "As above, and if a macOS release is waiting, Software Update is opened so "
                 + "macOS can ask for your password itself. That is the only way a macOS "
                 + "release can be installed: softwareupdate refuses it even as root, because "
                 + "Apple Silicon requires a volume owner's credentials."
        }
    }

    @State private var selected: Set<String> = []
    @State private var showOthers = false
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 0) {
            headerBlock
            Divider()
            if checker.results.isEmpty && !checker.isChecking {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Updates")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Compares what is installed against the latest version each vendor publishes. Updating reinstalls from the same source you originally used.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    Task { await checker.check(apps: state.allApps) }
                } label: {
                    Label(checker.isChecking ? "Checking…" : "Check Now",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(checker.isChecking)
            }

            automaticBlock

            if checker.isChecking {
                ProgressView(value: checker.progress).progressViewStyle(.linear)
            } else if let when = checker.lastChecked {
                HStack(spacing: 10) {
                    Text("Checked \(when.formatted(date: .omitted, time: .shortened))")
                    if !checker.updates.isEmpty {
                        Text("· \(checker.updates.count) update\(checker.updates.count == 1 ? "" : "s") available")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
    }

    private var automaticBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                Toggle("Check when MacSetup opens", isOn: Binding(
                    get: { checker.checkOnLaunch },
                    set: { checker.checkOnLaunch = $0 }))
                Toggle("Notify me", isOn: Binding(
                    get: { checker.notifyOnUpdates },
                    set: { checker.notifyOnUpdates = $0 }))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))

            HStack(spacing: 10) {
                Toggle("Run on a schedule", isOn: Binding(
                    get: { schedule.isInstalled },
                    set: { on in on ? schedule.install() : schedule.uninstall() }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))

                if schedule.isInstalled {
                    Picker("", selection: Binding(
                        get: { schedule.frequency },
                        set: { schedule.frequency = $0; schedule.install() })) {
                        ForEach(UpdateSchedule.Frequency.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()

                    Text("at").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { schedule.hour },
                        set: { schedule.hour = $0; schedule.install() })) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()

                    Picker("", selection: Binding(
                        get: { schedule.action },
                        set: { schedule.action = $0; schedule.install() })) {
                        ForEach(UpdateSchedule.Action.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Spacer()
            }

            if schedule.isInstalled {
                Text(schedule.action == .installWithPrompt
                     ? "Runs \(schedule.frequency.label.lowercased()) at \(String(format: "%02d:00", schedule.hour)) and installs everything, including packages and Apple updates. macOS will show its authorisation dialog — if nobody answers within 10 minutes the run gives up rather than leaving a dialog on screen. Anything needing a restart is still left alone."
                     : schedule.action == .install
                     ? "Runs \(schedule.frequency.label.lowercased()) at \(String(format: "%02d:00", schedule.hour)) and installs what it can without a password. Apps that are open are left alone rather than replaced underneath you, and anything needing an administrator is reported instead — nobody is there at midnight to approve it."
                     : "Runs \(schedule.frequency.label.lowercased()) at \(String(format: "%02d:00", schedule.hour)) and notifies you if anything is out of date, even when MacSetup is closed.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Without this, updates are only noticed while MacSetup is open.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            if schedule.isInstalled {
                HStack(spacing: 10) {
                    Button {
                        schedule.runNow()
                    } label: {
                        Label("Run now", systemImage: "play.circle")
                    }
                    .disabled(engine.isRunning)
                    .help("Runs the scheduled job immediately, exactly as it would at its usual time")

                    Text(schedule.summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                Toggle("Start MacSetup at login", isOn: Binding(
                    get: { loginAtStart },
                    set: { on in
                        loginError = LoginItem.set(on)
                        loginAtStart = LoginItem.isEnabled
                    }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Text(LoginItem.statusText)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
            }
            if let loginError {
                Text(loginError).font(.system(size: 11)).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Toggle("Show a full-screen reminder until macOS is updated", isOn: Binding(
                    get: { nagEnabled },
                    set: { nagEnabled = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                if nagEnabled {
                    Text("after").font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { nagAfterDays }, set: { nagAfterDays = $0 })) {
                        ForEach([0, 3, 7, 14, 30], id: \.self) { d in
                            Text(d == 0 ? "straight away" : "\(d) days").tag(d)
                        }
                    }.labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Spacer()
            }

            Text(nagEnabled
                 ? "Covers every display at login and at each unlock, until the update is installed. "
                 + "A deferral is always offered — it shortens to \(nagLateSnooze) minutes after "
                 + "\(nagDeadlineDays) days, but never disappears, so nobody gets trapped mid-presentation."
                 : "Off. macOS updates are only mentioned in notifications.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    cacheMessage = "Starting the download…"
                    Task { await cacheInstaller() }
                } label: {
                    Label("Download the macOS installer now", systemImage: "arrow.down.circle")
                }
                .disabled(caching || !system.updates.contains(where: \.isSystemRelease))
                .help("Fetches the full installer ahead of time, so updating later is quick")
                if let cacheMessage {
                    Text(cacheMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if system.updates.contains(where: \.isSystemRelease) {
                Text(OSInstallerCache.cached().contains(where: OSInstallerCache.isComplete)
                     ? "macOS is downloaded and ready. Upgrade Now opens Apple's installer — your files and apps are kept, and it will ask for your password and restart."
                     : "macOS updates are installed by Apple's own installer, not by MacSetup: Apple requires your password for a system release. Download it now to make upgrading later quick, or go straight to Software Update.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let osDownloadMessage {
                Text(osDownloadMessage)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("When you next unlock this Mac")
                    .font(.system(size: 12))
                Picker("", selection: $unlockAction) {
                    ForEach(UnlockAction.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            }

            Text(unlockExplanation)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let err = schedule.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No update check has run yet")
                .font(.system(size: 14, weight: .medium))
            Text("Only apps from this catalogue that are already installed are checked.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Button("Check Now") { Task { await checker.check(apps: state.allApps) } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !checker.updates.isEmpty {
                    sectionHeader("Available updates (\(checker.updates.count))") {
                        Button("Select all") { selected = Set(checker.updates.map(\.id)) }
                        Button("None") { selected.removeAll() }
                    }
                    ForEach(checker.updates) { row($0, selectable: true) }

                    Button {
                        let apps = state.allApps.filter { selected.contains($0.id) }
                        engine.run(apps: apps, tweaks: [], options: reinstallOptions)
                        showQueue = true
                    } label: {
                        Label("Update \(selected.count) App\(selected.count == 1 ? "" : "s")",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || engine.isRunning)
                    .padding(.top, 2)
                }

                stagedSection
                systemSection
                appStoreSection

                let current = checker.results.filter { if case .upToDate = $0.state { return true }; return false }
                if !current.isEmpty {
                    sectionHeader("Up to date (\(current.count))") { EmptyView() }
                    ForEach(current) { row($0, selectable: false) }
                }

                if !checker.unknowns.isEmpty {
                    sectionHeader("Could not determine (\(checker.unknowns.count))") {
                        Button(showOthers ? "Hide" : "Show") { showOthers.toggle() }
                    }
                    if showOthers {
                        Text("These either ship their own updater or publish no version number. MacSetup will not guess — reinstalling from the catalogue always fetches the current build.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(checker.unknowns) { row($0, selectable: false) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Updates downloaded overnight and waiting for a restart.
    @ViewBuilder
    private var stagedSection: some View {
        if !staged.staged.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("Ready to install — needs a restart", systemImage: "restart.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)

                ForEach(staged.staged) { u in
                    HStack(spacing: 9) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(u.title) \(u.version)")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("Downloaded \(u.stagedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08)))
                }

                HStack(spacing: 10) {
                    Button {
                        let toInstall = system.updates.filter { u in
                            staged.staged.contains { $0.label == u.label }
                        }
                        engine.runSystemUpdates(toInstall, options: state.options)
                        staged.clear(toInstall.map(\.label))
                        showQueue = true
                    } label: {
                        Label("Install and let macOS restart", systemImage: "restart")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(engine.isRunning)

                    Button("Not now") { }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .help("You will be asked again the next time you unlock your Mac")
                    Spacer()
                }

                Text("Already downloaded, so installing is quick. MacSetup will not restart your Mac by itself — macOS asks once the install finishes.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.07)))
        }
    }

    /// macOS and Apple updates. Listed here, but never installed automatically:
    /// they need root and can force a restart, which is not a decision this tool
    /// should take on someone's behalf.
    @ViewBuilder
    private var systemSection: some View {
        if system.isChecking || !system.updates.isEmpty || system.lastChecked != nil {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text("macOS & Apple software")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer()
                    if !system.updates.isEmpty {
                        Text("\(state.selectedSystemUpdates.count) of \(system.updates.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Select All") {
                            // Never a macOS release: selecting one would queue
                            // softwareupdate -i, which downloads gigabytes and
                            // then always fails to authenticate.
                            state.selectedSystemUpdates = Set(
                                system.updates.filter { !$0.isSystemRelease }.map(\.label))
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                        Button("None") { state.selectedSystemUpdates.removeAll() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                            .disabled(state.selectedSystemUpdates.isEmpty)
                    }
                    Button(system.isChecking ? "Checking…" : "Check") {
                        Task { await system.check() }
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                    .disabled(system.isChecking)
                }

                if system.isChecking {
                    Text("Asking Apple… this can take a minute.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let err = system.lastError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                } else if system.updates.isEmpty {
                    Label("macOS is up to date", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    ForEach(system.updates) { u in
                        Button {
                            // A macOS release is not a checkbox. It cannot be
                            // installed by this app at all, so the row does the
                            // only thing that works instead of queueing a run
                            // that is guaranteed to fail.
                            if u.isSystemRelease {
                                // The buttons on the right do the work now.
                            } else if state.selectedSystemUpdates.contains(u.label) {
                                state.selectedSystemUpdates.remove(u.label)
                            } else {
                                state.selectedSystemUpdates.insert(u.label)
                            }
                        } label: {
                            HStack(spacing: 9) {
                                // No checkbox on a macOS release: it is not
                                // something this app can queue, and offering a
                                // tick implies otherwise.
                                Image(systemName: u.isSystemRelease
                                      ? "arrow.up.forward.app"
                                      : (state.selectedSystemUpdates.contains(u.label)
                                         ? "checkmark.circle.fill" : "circle"))
                                    .font(.system(size: 15))
                                    .foregroundStyle(u.isSystemRelease
                                                     ? Color.secondary
                                                     : (state.selectedSystemUpdates.contains(u.label)
                                                        ? Color.accentColor : Color.secondary.opacity(0.5)))
                                Image(systemName: u.requiresRestart ? "restart.circle" : "apple.logo")
                                    .foregroundStyle(u.requiresRestart ? Color.orange : Color.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(u.title).font(.system(size: 12.5, weight: .medium))
                                    Text("\(u.version) · \(u.sizeText)")
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if u.isSystemRelease {
                                    // Spelled out as buttons rather than a
                                    // clickable row. Colleagues should not
                                    // have to guess that a row is a control,
                                    // and never have to open a terminal.
                                    if let ready = OSInstallerCache.cached(matching: u) {
                                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.green)
                                        Button("Upgrade Now…") { OSInstallerCache.open(ready) }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .help("Opens Apple's installer. Your files and apps are kept.")
                                    } else {
                                        Button("Download \(u.sizeText)") {
                                            osDownloadMessage = "Opening Terminal — Apple shows the progress there."
                                            startOSDownload(u)
                                        }
                                        .controlSize(.small)
                                        .help("Downloads the installer now so upgrading later is quick")
                                        Button("Software Update…") { UnlockThrottle.openSoftwareUpdate() }
                                            .controlSize(.small)
                                            .help("Install it the usual way, through System Settings")
                                    }
                                }
                                if u.requiresRestart {
                                    Text("restart")
                                        .font(.system(size: 9.5, weight: .medium))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.16), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 5).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(state.selectedSystemUpdates.contains(u.label)
                                      ? Color.accentColor.opacity(0.08)
                                      : Color(nsColor: .controlBackgroundColor)))
                        }
                        .buttonStyle(.plain)
                    }

                    if !state.selectedSystemUpdates.isEmpty {
                        Text("Selected updates install with the button at the bottom, together with any apps.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if system.updates.contains(where: { state.selectedSystemUpdates.contains($0.label) && $0.requiresRestart }) {
                        Label("One of these needs a restart. MacSetup installs it but will not reboot your Mac — macOS will ask when you are ready.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button("Open Software Update") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        Text("Or use Software Update directly.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        }
    }

    /// App Store apps. These can only be updated by the App Store itself, so
    /// this reports state and sends you there rather than pretending otherwise.
    @ViewBuilder
    private var appStoreSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("App Store")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if !store.receiptApps.isEmpty {
                    Text("\(store.receiptApps.count) installed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(store.isChecking ? "Checking…" : "Check") {
                    Task { await store.check() }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
                .disabled(store.isChecking)
            }

            switch store.state {
            case .notChecked:
                Text("Not checked yet.").font(.system(size: 11)).foregroundStyle(.secondary)

            case .masMissing:
                HStack(spacing: 8) {
                    Label("Install mas to read App Store versions", systemImage: "bag")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Add mas") {
                        if let m = state.app(id: "mas") { state.selectedApps.insert(m.id) }
                    }
                    .font(.caption)
                }

            case .cannotDetect:
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(store.receiptApps.count) App Store app\(store.receiptApps.count == 1 ? "" : "s") installed",
                          systemImage: "bag.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text(store.receiptApps.prefix(6).joined(separator: ", ")
                         + (store.receiptApps.count > 6 ? " and \(store.receiptApps.count - 6) more" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Their versions cannot be read on this macOS: mas relies on a Spotlight attribute that Apple no longer populates, so reindexing will not help. Update them in the App Store.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .upToDate(let n):
                Label("\(n) App Store app\(n == 1 ? "" : "s"), all up to date",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.green)

            case .updates(let list):
                ForEach(list) { u in
                    HStack(spacing: 9) {
                        Image(systemName: "bag.fill").foregroundStyle(.blue).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.name).font(.system(size: 12.5, weight: .medium))
                            HStack(spacing: 4) {
                                Text(u.installed).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                Text(u.latest).foregroundStyle(.orange).fontWeight(.medium)
                            }
                            .font(.system(size: 10.5))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }

            Button("Open App Store Updates") {
                if let u = URL(string: "macappstore://showUpdatesPage") { NSWorkspace.shared.open(u) }
            }
            .font(.caption)
            .padding(.top, 2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
    }

    /// Updating must not skip an app just because it is already present.
    private var reinstallOptions: ScriptOptions {
        var o = state.options
        o.skipInstalled = false
        return o
    }

    private func sectionHeader<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            Spacer()
            trailing().buttonStyle(.plain).font(.caption).foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private func row(_ r: UpdateResult, selectable: Bool) -> some View {
        let app = state.app(id: r.id)
        HStack(spacing: 10) {
            if selectable {
                Button {
                    if selected.contains(r.id) { selected.remove(r.id) } else { selected.insert(r.id) }
                } label: {
                    Image(systemName: selected.contains(r.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(selected.contains(r.id) ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            if let app { AppIconView(app: app, side: 26) }

            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(.system(size: 12.5, weight: .medium))
                switch r.state {
                case .available(let i, let l):
                    HStack(spacing: 4) {
                        Text(i).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                        Text(l).foregroundStyle(.orange).fontWeight(.medium)
                        Text("· via \(r.via)").foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 10.5))
                case .upToDate(let v):
                    Text("\(v) · via \(r.via)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                case .unknown(let v, let why):
                    Text("\(v) · \(why)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if case .upToDate = r.state {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(r.state.isUpdate ? Color.orange.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
    }
}
