import SwiftUI
import UniformTypeIdentifiers

struct ScriptSheet: View {
    let script: String
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generated Install Script")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Plain bash — review it, save it, or drop it into an onboarding runbook.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(script.components(separatedBy: "\n").count) lines")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)

            Divider()

            ScrollView {
                Text(script)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    exporting = true
                } label: {
                    Label("Save as .sh…", systemImage: "square.and.arrow.down")
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.bar)
        }
        .frame(minWidth: 520, idealWidth: 780, maxWidth: 1100,
               minHeight: 400, idealHeight: 600, maxHeight: .infinity)
        .fileExporter(isPresented: $exporting,
                      document: ScriptDocument(text: script),
                      contentType: .shellScript,
                      defaultFilename: "macsetup-install") { _ in }
    }
}

struct ScriptDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.shellScript, .plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents,
              let s = String(data: d, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = s
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Save profile

struct SaveProfileSheet: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Profile")
                .font(.system(size: 15, weight: .semibold))
            Text("Stores this selection so you can re-apply it on the next Mac, or export it for a colleague.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name, e.g. Business Baseline", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Text("\(state.selectedApps.count) apps · \(state.selectedTweaks.count) tweaks")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var p = state.currentProfile(named: name.trimmingCharacters(in: .whitespaces))
                    p.notes = notes
                    profiles.save(p)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 560)
    }
}
