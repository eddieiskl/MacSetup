import SwiftUI

struct RoleTemplatesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var profiles: ProfileStore
    @Binding var showSaveProfile: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Role Templates")
                        .font(.system(size: 17, weight: .semibold))
                    Text("A curated starting selection for a role or a way people actually use a Mac. Applying one replaces the current selection — review it, tweak it, then save it as your own profile if it's a good fit.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(state.roleTemplatesByGroup, id: \.group) { section in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(section.group)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 10)],
                                  spacing: 10) {
                            ForEach(section.templates) { template in
                                RoleTemplateCard(template: template, showSaveProfile: $showSaveProfile)
                            }
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
}

struct RoleTemplateCard: View {
    @EnvironmentObject var state: AppState
    let template: RoleTemplate
    @Binding var showSaveProfile: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: template.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                Text(template.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            Text(template.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(countLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Button("Apply") {
                    state.apply(template.asProfile)
                }
                Button("Apply & Save…") {
                    state.apply(template.asProfile)
                    showSaveProfile = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            }
            .font(.system(size: 12))
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var countLine: String {
        var bits: [String] = []
        let apps = template.appIDs.count
        if apps > 0 { bits.append("\(apps) app\(apps == 1 ? "" : "s")") }
        let web = template.webAppIDs.count
        if web > 0 { bits.append("\(web) web app\(web == 1 ? "" : "s")") }
        let tweaks = template.tweakIDs.count
        if tweaks > 0 { bits.append("\(tweaks) tweak\(tweaks == 1 ? "" : "s")") }
        return bits.joined(separator: " · ")
    }
}
