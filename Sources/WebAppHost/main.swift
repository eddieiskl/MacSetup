import AppKit
import WebKit

// A minimal browser window for one site. Each generated web app bundle embeds a
// copy of this binary and supplies its URL through Info.plist, so the app is a
// real application: its own Dock icon, its own window, its own Cmd-Tab entry.
//
// The trade-off against the browser launcher is sign-in. This has its own cookie
// store, so you sign in once here rather than sharing the browser's session —
// and Google actively blocks sign-in from embedded web views, which is why the
// browser launcher remains the default for Google and Microsoft sites.

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    private var home: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleName"] as? String ?? "Web App"
        let urlString = info["MSWebAppURL"] as? String ?? "https://example.com"
        home = URL(string: urlString) ?? URL(string: "https://example.com")!

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // persists across launches
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        if #available(macOS 13.3, *) { web.isInspectable = false }

        let frame = NSRect(x: 0, y: 0, width: 1180, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = name
        window.titlebarAppearsTransparent = false
        window.setFrameAutosaveName("MSWebAppWindow")
        window.contentView = web
        window.minSize = NSSize(width: 420, height: 400)
        window.center()
        window.makeKeyAndOrderFront(nil)

        buildMenu(appName: name)
        web.load(URLRequest(url: home))
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Links that open a new window (target="_blank") go to the real browser
    // rather than silently doing nothing.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not load \(home.host ?? "the page")"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            web.load(URLRequest(url: home))
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: Menu

    private func buildMenu(appName: String) {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, sel, key) in [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: title, action: sel, keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        view.addItem(withTitle: "Back", action: #selector(goBack), keyEquivalent: "[")
        view.addItem(withTitle: "Forward", action: #selector(goForward), keyEquivalent: "]")
        view.addItem(.separator())
        view.addItem(withTitle: "Home", action: #selector(goHome), keyEquivalent: "H")
        view.addItem(.separator())
        view.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "b")
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func reload() { web.reload() }
    @objc private func goBack() { web.goBack() }
    @objc private func goForward() { web.goForward() }
    @objc private func goHome() { web.load(URLRequest(url: home)) }
    @objc private func openInBrowser() {
        NSWorkspace.shared.open(web.url ?? home)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
