import SwiftUI
import MacSetupCore

/// Compare a saved profile or bundled Role Template against this Mac, then
/// selectively remediate through the existing install/update/tweak machinery.
///
/// Follows the same Define → Preview → Verify → Apply shape as the rest of
/// MacSetup: comparing never changes anything, "Preview Script" shows exactly
/// what would run, and only "Apply" touches the Mac.
struct DesiredStateView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var engine: InstallEngine
    @EnvironmentObject var desiredState: DesiredStateEngine

    @State private var selectionKey: String = ""
    @State private var showScript = false
    @State private var showQueue = false
    @State private var confirmingRemovals = false

    private var sources: [(key: String, label: String, source: DesiredStateSource, profile: Profile)] {
        var out: [(String, String, DesiredStateSource, Profile)] = []
        for p in profiles.profiles {
            out.append(("profile:\(p.id)", p.name, DesiredStateSource(kind: .profile, name: p.name), p))
        }
        for t in state.roleTemplates {
            out.append(("template:\(t.id)", t.name, DesiredStateSource(kind: .roleTemplate, name: t.name), t.asProfile))
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                picker
                if let report = desiredState.report { summary(report) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                if let report = desiredState.report {
                    findings(report)
                        .padding(20)
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if desiredState.report != nil {
                Divider()
                actionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showScript) { ScriptSheet(script: previewScript) }
        .sheet(isPresented: $showQueue) { QueueSheet() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Desired State")
                .font(.system(size: 17, weight: .semibold))
            Text("Compare one of your saved profiles or a bundled Role Template against what's actually on this Mac. Nothing changes until you choose remediation actions below and press Apply.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picker: some View {
        HStack(spacing: 10) {
            Picker("Compare against", selection: $selectionKey) {
                Text("Choose…").tag("")
                if !profiles.profiles.isEmpty {
                    Section("Profiles") {
                        ForEach(sources.filter { $0.key.hasPrefix("profile:") }, id: \.key) {
                            Text($0.label).tag($0.key)
                        }
                    }
                }
                Section("Role Templates") {
                    ForEach(sources.filter { $0.key.hasPrefix("template:") }, id: \.key) {
                        Text($0.label).tag($0.key)
                    }
                }
            }
            .frame(maxWidth: 320)

            Button {
                guard let match = sources.first(where: { $0.key == selectionKey }),
                      let catalog = state.catalog else { return }
                Task { await desiredState.compare(desired: match.profile, source: match.source, catalog: catalog) }
            } label: {
                if desiredState.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Compare")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectionKey.isEmpty || desiredState.isRunning)
        }
    }

    private func summary(_ report: DesiredStateReport) -> some View {
        HStack(spacing: 14) {
            statPill("Compliant", report.summary.compliant, .green)
            statPill("Missing", report.summary.missing, .red)
            statPill("Outdated", report.summary.outdated, .orange)
            statPill("Different", report.summary.different, .orange)
            statPill("Unknown", report.summary.unknown, .secondary)
            statPill("Extra", report.summary.extra, .secondary)
        }
    }

    private func statPill(_ label: String, _ count: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func findings(_ report: DesiredStateReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !report.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.warnings, id: \.self) { w in
                        Text("⚠︎ \(w)").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
            }

            findingSection("Apps", items: report.apps.filter { $0.status != .compliant }.map {
                (id: $0.id, name: $0.name, status: $0.status, detail: $0.detail,
                 actionID: actionID(kind: .installApp, target: $0.id) ?? actionID(kind: .updateApp, target: $0.id) ?? actionID(kind: .manualActionRequired, target: $0.id))
            })
            findingSection("Tweaks", items: report.tweaks.filter { $0.status != .compliant }.map {
                (id: $0.id, name: $0.name, status: $0.status, detail: $0.detail,
                 actionID: actionID(kind: .applyTweak, target: $0.id) ?? actionID(kind: .unsupported, target: $0.id))
            })
            findingSection("Web Apps", items: report.webApps.filter { $0.status != .compliant }.map {
                (id: $0.id, name: $0.name, status: $0.status, detail: $0.detail,
                 actionID: actionID(kind: .createWebApp, target: $0.id))
            })

            if !report.extraApps.isEmpty {
                extraAppsSection(report)
            }
        }
    }

    private func actionID(kind: RemediationActionKind, target: String) -> String? {
        desiredState.plan?.actions.first { $0.kind == kind && $0.targetID == target }?.id
    }

    private func findingSection(_ title: String,
                                items: [(id: String, name: String, status: ComplianceStatus, detail: String, actionID: String?)]) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(items, id: \.id) { item in
                        HStack(alignment: .top, spacing: 10) {
                            if let actionID = item.actionID {
                                Toggle("", isOn: Binding(
                                    get: { desiredState.selectedActionIDs.contains(actionID) },
                                    set: { _ in desiredState.toggleAction(actionID) }))
                                .labelsHidden()
                            } else {
                                Color.clear.frame(width: 14, height: 14)
                            }
                            statusBadge(item.status)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 12.5, weight: .medium))
                                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func extraAppsSection(_ report: DesiredStateReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Extra (\(report.extraApps.count))").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Toggle("Also propose removing extra apps", isOn: Binding(
                    get: { desiredState.includeRemovals },
                    set: { desiredState.includeRemovals = $0; desiredState.rebuildPlan() }))
                .toggleStyle(.switch)
                .font(.system(size: 11))
            }
            Text("Informational by default — nothing here is ever removed automatically. Turning this on lets you individually select removals below; each one still needs its own checkbox and a final confirmation.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(report.extraApps, id: \.path) { extra in
                HStack(alignment: .top, spacing: 10) {
                    if desiredState.includeRemovals, let actionID = actionID(kind: .removeApp, target: extra.path) {
                        Toggle("", isOn: Binding(
                            get: { desiredState.selectedActionIDs.contains(actionID) },
                            set: { _ in desiredState.toggleAction(actionID) }))
                        .labelsHidden()
                    } else {
                        Color.clear.frame(width: 14, height: 14)
                    }
                    Image(systemName: extra.isCatalogued ? "app.badge" : "app.dashed")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(extra.name).font(.system(size: 12.5, weight: .medium))
                        Text(extra.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func statusBadge(_ status: ComplianceStatus) -> some View {
        let (symbol, color): (String, Color) = {
            switch status {
            case .compliant: return ("checkmark.circle.fill", .green)
            case .missing: return ("xmark.circle.fill", .red)
            case .outdated: return ("arrow.up.circle.fill", .orange)
            case .different: return ("exclamationmark.triangle.fill", .orange)
            case .unknown: return ("questionmark.circle.fill", .secondary)
            case .extra: return ("plus.circle.fill", .secondary)
            case .notApplicable: return ("minus.circle", .secondary)
            }
        }()
        return Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
    }

    // MARK: - Remediation

    private var selectedResolution: RemediationResolver.Resolution? {
        guard let report = desiredState.report, let catalog = state.catalog else { return nil }
        return RemediationResolver.resolve(actions: desiredState.selectedActions,
                                           catalog: catalog, report: report)
    }

    private var previewScript: String {
        guard let r = selectedResolution else { return "" }
        let browser = state.browser
        if !r.removals.isEmpty && r.apps.isEmpty && r.tweaks.isEmpty && r.webApps.isEmpty {
            return ScriptGenerator.buildUninstall(targets: r.removals, options: state.options)
        }
        return ScriptGenerator.build(apps: r.apps, tweaks: r.tweaks, webApps: r.webApps,
                                     browser: browser, options: state.options, arch: state.arch)
    }

    /// Two independent buttons rather than one "Apply" that would have to
    /// guess which kind of selection to act on. Installs/updates/tweaks/web
    /// apps go through the ordinary install path; removals are always a
    /// separate, explicitly confirmed action — the same separation
    /// `InstallEngine.run` and `.runUninstall` already enforce.
    private var actionBar: some View {
        HStack(spacing: 14) {
            Text(actionSummary)
                .font(.system(size: 12.5))
            Spacer()
            Button("Preview Script") { showScript = true }
                .disabled(!hasInstallSelection && (selectedResolution?.removals.isEmpty ?? true))
            Button("Apply") {
                guard let r = selectedResolution else { return }
                engine.run(apps: r.apps, tweaks: r.tweaks, webApps: r.webApps,
                          browser: state.browser, options: state.options)
                showQueue = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isRunning || !hasInstallSelection)

            if desiredState.includeRemovals {
                Divider().frame(height: 16)
                Button("Remove \(selectedResolution?.removals.count ?? 0)…") { confirmingRemovals = true }
                    .foregroundStyle(.red)
                    .disabled(engine.isRunning || (selectedResolution?.removals.isEmpty ?? true))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
        .alert("Remove \(selectedResolution?.removals.count ?? 0) app(s)?",
               isPresented: $confirmingRemovals) {
            Button("Remove", role: .destructive) {
                guard let r = selectedResolution, !r.removals.isEmpty else { return }
                engine.runUninstall(targets: r.removals, options: state.options)
                showQueue = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the selected app(s) to the Trash. It cannot be undone from here.")
        }
    }

    private var hasInstallSelection: Bool {
        guard let r = selectedResolution else { return false }
        return !r.apps.isEmpty || !r.tweaks.isEmpty || !r.webApps.isEmpty
    }

    private var actionSummary: String {
        guard let r = selectedResolution else { return "Nothing selected" }
        var bits: [String] = []
        if !r.apps.isEmpty { bits.append("\(r.apps.count) app\(r.apps.count == 1 ? "" : "s")") }
        if !r.tweaks.isEmpty { bits.append("\(r.tweaks.count) tweak\(r.tweaks.count == 1 ? "" : "s")") }
        if !r.webApps.isEmpty { bits.append("\(r.webApps.count) web app\(r.webApps.count == 1 ? "" : "s")") }
        if !r.removals.isEmpty { bits.append("\(r.removals.count) removal\(r.removals.count == 1 ? "" : "s")") }
        return bits.isEmpty ? "Nothing selected" : bits.joined(separator: " · ") + " selected"
    }
}
