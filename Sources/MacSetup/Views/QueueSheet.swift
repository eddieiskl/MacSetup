import SwiftUI

struct QueueSheet: View {
    @EnvironmentObject var engine: InstallEngine
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if engine.isPaused {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    Text("Paused. The item in flight was allowed to finish; nothing was interrupted.")
                        .font(.system(size: 11.5))
                    Spacer()
                    Button("Resume") { engine.resume() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            if engine.showAuthNotice && engine.isRunning {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text("macOS will ask for your administrator password to install packages. Approve the dialog to continue.")
                        .font(.system(size: 11.5))
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(engine.items) { item in
                            QueueRow(item: item).id(item.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: engine.items.filter { $0.state.isTerminal }.count) { _, _ in
                    if let next = engine.items.first(where: { !$0.state.isTerminal }) {
                        withAnimation { proxy.scrollTo(next.id, anchor: .center) }
                    }
                }
            }

            if showLog {
                Divider()
                ScrollView {
                    Text(engine.rawLog.isEmpty ? "No output yet." : engine.rawLog)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 170)
                .background(Color(nsColor: .textBackgroundColor))
            }

            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 620, maxWidth: 900,
               minHeight: 380, idealHeight: showLog ? 700 : 540, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(engine.isPaused ? "Paused"
                     : (engine.isRunning ? "Installing…" : "Finished"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(engine.isPaused ? Color.orange : Color.primary)
                Spacer()
                let c = engine.counts
                HStack(spacing: 12) {
                    stat("\(c.done)", "installed", .green)
                    if c.skipped > 0 { stat("\(c.skipped)", "skipped", .secondary) }
                    if c.failed > 0 { stat("\(c.failed)", "failed", .red) }
                    if c.remaining > 0 { stat("\(c.remaining)", "left", .secondary) }
                }
            }
            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private func stat(_ n: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(n).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(showLog ? "Hide Log" : "Show Log") { withAnimation { showLog.toggle() } }
            Button("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.rawLog, forType: .string)
            }
            .disabled(engine.rawLog.isEmpty)
            Spacer()
            if engine.isRunning {
                Button {
                    engine.togglePause()
                } label: {
                    Label(engine.isPaused ? "Resume" : "Pause",
                          systemImage: engine.isPaused ? "play.fill" : "pause.fill")
                }
                .help(engine.isPaused
                      ? "Continue with the next item"
                      : "Hold after the item in flight finishes — nothing is interrupted midway")
                Button("Cancel", role: .destructive) { engine.cancel() }
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(.bar)
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: 10) {
            QueueIconView(itemID: item.id, side: 24)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: item.state.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(item.state.tint)
                        .padding(1.5)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: 4, y: 4)
                        .symbolEffect(.pulse, options: .repeating,
                                      isActive: !item.state.isTerminal && item.state != .pending)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(item.state == .failed ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)

            if case .downloading(let pct) = item.state {
                VStack(alignment: .trailing, spacing: 2) {
                    if pct >= 0 {
                        ProgressView(value: Double(pct), total: 100)
                            .progressViewStyle(.linear)
                            .frame(width: 92)
                    } else {
                        ProgressView().progressViewStyle(.linear).frame(width: 92)
                    }
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(item.state.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(item.state.tint)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(item.state == .failed ? Color.red.opacity(0.07)
                                        : Color(nsColor: .controlBackgroundColor)))
    }

    private var subtitle: String {
        if case .downloading = item.state { return item.subtitle }
        if item.state == .failed, !item.detail.isEmpty { return item.detail }
        if !item.signature.isEmpty, item.state.isTerminal { return "\(item.subtitle) · \(item.signature)" }
        return item.subtitle
    }
}
