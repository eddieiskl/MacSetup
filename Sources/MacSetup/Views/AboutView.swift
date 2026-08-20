import SwiftUI
import AppKit

struct AboutView: View {
    @EnvironmentObject var state: AppState
    private let info = AboutInfo.load()

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return b == v ? "Version \(v)" : "Version \(v) (\(b))"
    }

    private var appIcon: NSImage? {
        NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !info.author.name.isEmpty { authorCard }
                    catalogueCard
                    if !info.acknowledgements.isEmpty { acknowledgements }
                    footerText
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable().interpolation(.high)
                    .frame(width: 76, height: 76)
            }
            Text("MacSetup").font(.system(size: 22, weight: .semibold))
            Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
            if !info.tagline.isEmpty {
                Text(info.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22).padding(.bottom, 16).padding(.horizontal, 20)
    }

    private var authorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Made by")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)

            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Text(initials)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.author.name).font(.system(size: 14, weight: .semibold))
                    if !info.author.role.isEmpty {
                        Text(info.author.role).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !info.organisation.isEmpty {
                        Text(info.organisation).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if !info.links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(info.links, id: \.label) { link in
                        Button {
                            if let u = URL(string: link.url) { NSWorkspace.shared.open(u) }
                        } label: {
                            Label(link.label, systemImage: link.symbol)
                                .font(.system(size: 11.5))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }

            if !info.supportNote.isEmpty {
                Text(info.supportNote)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var initials: String {
        let parts = info.author.name.split(separator: " ")
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first {
            return "\(a)\(b)".uppercased()
        }
        return String(info.author.name.prefix(1)).uppercased()
    }

    private var catalogueCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("This build")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            grid([
                ("Applications", "\(state.allApps.count)"),
                ("Web apps", "\(state.allWebApps.count)"),
                ("Categories", "\(state.categories.count)"),
                ("System tweaks", "\(state.catalog?.systemDefaults.count ?? 0)"),
                ("Catalogue updated", state.catalog?.updated ?? "—"),
                ("This Mac", state.arch.display),
            ])
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How it works")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(info.acknowledgements, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footerText: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !info.license.isEmpty {
                Text(info.license).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            if !info.copyright.isEmpty {
                Text(info.copyright).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
