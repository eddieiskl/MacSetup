import SwiftUI

/// Small icon for a catalogue entry. Resolves lazily, so only the cards you
/// actually scroll past ever trigger a lookup.
struct IconView: View {
    @EnvironmentObject var icons: IconProvider
    let target: IconTarget
    var side: CGFloat = 30
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: side * 0.22)
                    .fill(Color.secondary.opacity(0.13))
                    .overlay(ProgressView().controlSize(.mini).scaleEffect(0.55))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22))
        .task(id: target.key) { image = await icons.image(for: target) }
    }
}

/// Convenience wrappers so call sites stay readable.
struct AppIconView: View {
    let app: CatalogApp
    var side: CGFloat = 30
    var body: some View { IconView(target: IconTarget(app), side: side) }
}

struct WebIconView: View {
    let web: WebApp
    var side: CGFloat = 30
    var body: some View { IconView(target: IconTarget(web), side: side) }
}

/// Queue rows key off an id rather than a full catalogue entry.
struct QueueIconView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var icons: IconProvider
    let itemID: String
    var side: CGFloat = 22

    var body: some View {
        if let app = state.allApps.first(where: { $0.id == itemID }) {
            AppIconView(app: app, side: side)
        } else if let web = state.allWebApps.first(where: { $0.id == itemID }) {
            WebIconView(web: web, side: side)
        } else {
            RoundedRectangle(cornerRadius: side * 0.22)
                .fill(Color.secondary.opacity(0.13))
                .frame(width: side, height: side)
                .overlay(Image(systemName: "slider.horizontal.3")
                    .font(.system(size: side * 0.45))
                    .foregroundStyle(.secondary))
        }
    }
}
