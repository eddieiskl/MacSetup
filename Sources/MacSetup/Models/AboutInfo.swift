import Foundation

/// Details shown in the About window.
///
/// Kept in `about.json` rather than hard-coded so it can be edited inside a
/// built MacSetup.app — right-click the app, Show Package Contents, and edit
/// `Contents/Resources/about.json`. No rebuild needed.
struct AboutInfo: Codable {
    struct Author: Codable {
        var name: String
        var role: String
        var email: String
        var website: String
        var github: String
        var linkedin: String
    }

    var author: Author
    var organisation: String
    var tagline: String
    var copyright: String
    var license: String
    var supportNote: String
    var acknowledgements: [String]

    static let fallback = AboutInfo(
        author: Author(name: "", role: "", email: "", website: "", github: "", linkedin: ""),
        organisation: "",
        tagline: "Provision a new Mac from a curated catalogue.",
        copyright: "",
        license: "",
        supportNote: "",
        acknowledgements: []
    )

    static func load() -> AboutInfo {
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: "about", withExtension: "json") { candidates.append(u) }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("about.json")) }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("about.json"))
        candidates.append(exeDir.appendingPathComponent("MacSetup_MacSetup.bundle/about.json"))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let d = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(AboutInfo.self, from: d) {
                return decoded
            }
        }
        return .fallback
    }

    /// Links that are actually filled in, ready to render.
    var links: [(label: String, symbol: String, url: String)] {
        var out: [(String, String, String)] = []
        if !author.email.isEmpty { out.append(("Email", "envelope", "mailto:\(author.email)")) }
        if !author.website.isEmpty { out.append(("Website", "globe", normalise(author.website))) }
        if !author.github.isEmpty { out.append(("GitHub", "chevron.left.forwardslash.chevron.right", normalise(author.github))) }
        if !author.linkedin.isEmpty { out.append(("LinkedIn", "person.crop.square", normalise(author.linkedin))) }
        return out
    }

    private func normalise(_ s: String) -> String {
        s.lowercased().hasPrefix("http") ? s : "https://\(s)"
    }
}
