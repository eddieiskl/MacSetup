import Foundation
import AppKit

/// A site installed as a standalone .app that opens in its own window.
public struct WebApp: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let group: String
    public let url: String
    public let summary: String
    public let icon: String?          // explicit icon when the host serves none

    public var host: String { URL(string: url)?.host ?? "" }

    /// User-created entries are kept apart from the shipped catalogue.
    public var isCustom: Bool { id.hasPrefix("custom-") }

    public init(id: String, name: String, group: String, url: String, summary: String, icon: String?) {
        self.id = id
        self.name = name
        self.group = group
        self.url = url
        self.summary = summary
        self.icon = icon
    }

    public static func custom(name: String, url: String) -> WebApp {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return WebApp(id: "custom-\(slug.isEmpty ? UUID().uuidString.prefix(6).lowercased() : slug)",
                      name: name, group: "Custom", url: url,
                      summary: URL(string: url)?.host ?? url, icon: nil)
    }
}

// MARK: - Browsers

public struct BrowserInfo: Identifiable, Hashable {
    public let bundleID: String
    public let name: String
    public let path: String
    /// Chromium browsers support `--app=URL`, which is what makes a real
    /// standalone window rather than just another tab.
    public let supportsAppMode: Bool

    public var id: String { bundleID }

    /// Path to the actual executable inside the bundle, needed because
    /// `open --args` cannot pass flags to an already-running browser.
    public var executablePath: String {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url),
              let exe = bundle.executableURL else {
            return path + "/Contents/MacOS/" + url.deletingPathExtension().lastPathComponent
        }
        return exe.path
    }
}

public enum BrowserDetector {
    /// Ordered by how well each one handles app mode.
    private static let known: [(String, String, Bool)] = [
        ("com.google.Chrome",           "Google Chrome",  true),
        ("com.microsoft.edgemac",       "Microsoft Edge", true),
        ("com.brave.Browser",           "Brave",          true),
        ("com.vivaldi.Vivaldi",         "Vivaldi",        true),
        ("org.chromium.Chromium",       "Chromium",       true),
        ("company.thebrowser.Browser",  "Arc",            false),
        ("com.apple.Safari",            "Safari",         false),
        ("org.mozilla.firefox",         "Firefox",        false),
    ]

    public static func installed() -> [BrowserInfo] {
        known.compactMap { bundleID, name, appMode in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return BrowserInfo(bundleID: bundleID, name: name, path: url.path, supportsAppMode: appMode)
        }
    }

    /// The browser macOS would use for a plain https link.
    public static func systemDefault() -> BrowserInfo? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL)?.bundleIdentifier else { return nil }
        if let match = known.first(where: { $0.0 == bundle }) {
            return BrowserInfo(bundleID: bundle, name: match.1, path: appURL.path, supportsAppMode: match.2)
        }
        return BrowserInfo(bundleID: bundle,
                           name: appURL.deletingPathExtension().lastPathComponent,
                           path: appURL.path,
                           supportsAppMode: false)
    }
}
