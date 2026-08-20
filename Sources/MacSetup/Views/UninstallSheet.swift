import SwiftUI

/// Removing apps sits behind its own confirmation and never shares a button
/// with installing.
struct UninstallSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: InstallEngine
    @Environment(\.dismiss) private var dismiss
    let targets: [UninstallTarget]
    let names: [String]
    var onStart: () -> Void = {}
    @State private var confirmed = false

    private var packaged: [UninstallTarget] { targets.filter { $0.kind == "pkg" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Move \(targets.count) app\(targets.count == 1 ? "" : "s") to the Trash?",
                  systemImage: "trash")
                .font(.system(size: 15, weight: .semibold))

            Text("Each bundle is moved to the Trash, or removed through Homebrew if that is how it arrived. Preferences, licences and documents are left untouched — nothing is deleted outright, and you can put anything back from the Trash.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(targets) { t in
                        HStack(spacing: 7) {
                            Text(t.name).font(.system(size: 12))
                            Spacer()
                            Text(t.kind == "brew" ? "homebrew" : (t.kind == "pkg" ? "package" : "app"))
                                .font(.system(size: 9.5))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background((t.kind == "pkg" ? Color.orange : Color.secondary).opacity(0.16),
                                            in: Capsule())
                                .foregroundStyle(t.kind == "pkg" ? Color.orange : Color.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: 190)

            if !packaged.isEmpty {
                Text("\(packaged.count) of these were installed from a package. A package writes files across the system, so MacSetup reports them rather than removing them — use the vendor's own uninstaller.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("I understand these will be moved to the Trash", isOn: $confirmed)
                .toggleStyle(.checkbox).font(.system(size: 12))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    engine.runUninstall(targets: targets, options: state.options)
                    onStart()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!confirmed)
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 470, maxWidth: 620)
    }
}
