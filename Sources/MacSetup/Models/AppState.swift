import Foundation
import SwiftUI
import Combine

enum SortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case vendor = "Vendor"
    case category = "Category"
    var id: String { rawValue }
}

@MainActor
final class AppState: ObservableObject {

    // Catalog
    @Published private(set) var catalog: Catalog?
    @Published private(set) var loadError: String?

    // Selection
    @Published var selectedApps: Set<String> = []
    @Published var selectedTweaks: Set<String> = []
    @Published var selectedWebApps: Set<String> = []
    /// Apple updates chosen for installation. Kept here, not in the Updates
    /// view, so one Install button covers apps, web apps, tweaks and macOS.
    @Published var selectedSystemUpdates: Set<String> = []
    @Published var customWebApps: [WebApp] = []
    @Published var browser: BrowserInfo?
    @Published private(set) var browsers: [BrowserInfo] = []

    // Filters
    @Published var search = ""
    @Published var category: String? = nil          // nil == every category
    @Published var activeTags: Set<String> = []
    @Published var licenseFilter: Set<String> = []
    @Published var sourceFilter: Set<SourceKind> = []
    @Published var hideInstalled = false
    @Published var hideAdminRequired = false
    @Published var sortOrder: SortOrder = .name

    // Options
    @Published var options = ScriptOptions()

    // Environment
    @Published private(set) var installedBundleIDs: Set<String> = []
    @Published private(set) var installedEntries: [InstalledEntry] = []
    @Published var showNonCatalogueApps = false
    @Published var installedSearch = ""
    let arch = Arch.current

    init() {
        do { catalog = try CatalogLoader.load() }
        catch { loadError = error.localizedDescription }
        appsByID = Dictionary(uniqueKeysWithValues: (catalog?.apps ?? []).map { ($0.id, $0) })
        browsers = BrowserDetector.installed()
        browser = BrowserDetector.systemDefault()
            ?? browsers.first(where: \.supportsAppMode)
            ?? browsers.first
        loadCustomWebApps()
        precomputeCounts()
        recomputeFiltered()
        observeFilters()
        Task { await scanInstalled() }
    }

    /// Counts the sidebar shows. Recomputing these meant filtering all 162 apps
    /// once per category and once per quick pick, every time the sidebar drew.
    private(set) var categoryCounts: [String: Int] = [:]
    private(set) var tagCounts: [String: Int] = [:]
    /// Icon targets parse URLs, so build them once rather than per card render.
    private var iconTargets: [String: IconTarget] = [:]

    func iconTarget(for app: CatalogApp) -> IconTarget {
        iconTargets[app.id] ?? IconTarget(app)
    }

    private func precomputeCounts() {
        var cats: [String: Int] = [:]
        var tags: [String: Int] = [:]
        var targets: [String: IconTarget] = [:]
        for a in allApps {
            cats[a.category, default: 0] += 1
            for t in a.tags { tags[t, default: 0] += 1 }
            targets[a.id] = IconTarget(a)
        }
        categoryCounts = cats
        tagCounts = tags
        iconTargets = targets
    }

    private var filterObservers: [AnyCancellable] = []

    /// Recompute only when something that affects the list actually changes.
    private func observeFilters() {
        let triggers: [AnyPublisher<Void, Never>] = [
            $search.map { _ in () }.eraseToAnyPublisher(),
            $category.map { _ in () }.eraseToAnyPublisher(),
            $activeTags.map { _ in () }.eraseToAnyPublisher(),
            $licenseFilter.map { _ in () }.eraseToAnyPublisher(),
            $sourceFilter.map { _ in () }.eraseToAnyPublisher(),
            $hideInstalled.map { _ in () }.eraseToAnyPublisher(),
            $hideAdminRequired.map { _ in () }.eraseToAnyPublisher(),
            $sortOrder.map { _ in () }.eraseToAnyPublisher(),
            $installedBundleIDs.map { _ in () }.eraseToAnyPublisher(),
        ]
        for t in triggers {
            t.receive(on: RunLoop.main)
                .sink { [weak self] in self?.recomputeFiltered() }
                .store(in: &filterObservers)
        }
    }

    // MARK: - Derived collections

    var categories: [AppCategory] {
        (catalog?.categories ?? []).sorted { $0.order < $1.order }
    }

    var allApps: [CatalogApp] { catalog?.apps ?? [] }

    var allTags: [String] {
        Array(Set(allApps.flatMap(\.tags))).sorted()
    }

    var allLicenses: [String] {
        Array(Set(allApps.map(\.license))).sorted()
    }

    /// Apps left after every active filter, in the chosen sort order.
    ///
    /// Cached: this is read several times per render, and recomputing a filter
    /// and a sort over the whole catalogue each time showed up as scroll stutter.
    @Published private(set) var filteredApps: [CatalogApp] = []
    private var appsByID: [String: CatalogApp] = [:]

    func app(id: String) -> CatalogApp? { appsByID[id] }

    private func recomputeFiltered() {
        filteredApps = computeFilteredApps()
    }

    private func computeFilteredApps() -> [CatalogApp] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var result = allApps.filter { app in
            if let category, app.category != category { return false }
            if !needle.isEmpty, !app.searchHaystack.contains(needle) { return false }
            if !activeTags.isEmpty, activeTags.isDisjoint(with: Set(app.tags)) { return false }
            if !licenseFilter.isEmpty, !licenseFilter.contains(app.license) { return false }
            if !sourceFilter.isEmpty, !sourceFilter.contains(app.source.kind) { return false }
            if hideInstalled, isInstalled(app) { return false }
            if hideAdminRequired, app.needsRoot { return false }
            return true
        }
        switch sortOrder {
        case .name:   result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .vendor: result.sort { ($0.vendor, $0.name) < ($1.vendor, $1.name) }
        case .category:
            let order = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.order) })
            result.sort { (order[$0.category] ?? 99, $0.name) < (order[$1.category] ?? 99, $1.name) }
        }
        return result
    }

    var tweaksByGroup: [(group: String, tweaks: [DefaultTweak])] {
        let all = catalog?.systemDefaults ?? []
        let grouped = Dictionary(grouping: all, by: \.group)
        let order = all.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var selectedAppObjects: [CatalogApp] {
        // Preserve catalogue order so the generated script reads predictably.
        allApps.filter { selectedApps.contains($0.id) }
    }

    var selectedTweakObjects: [DefaultTweak] {
        (catalog?.systemDefaults ?? []).filter { selectedTweaks.contains($0.id) }
    }

    var hasSelection: Bool {
        !selectedApps.isEmpty || !selectedTweaks.isEmpty
            || !selectedWebApps.isEmpty || !selectedSystemUpdates.isEmpty
    }

    var allWebApps: [WebApp] { (catalog?.webAppList ?? []) + customWebApps }

    var webAppsByGroup: [(group: String, apps: [WebApp])] {
        let all = allWebApps
        let grouped = Dictionary(grouping: all, by: \.group)
        let order = all.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var selectedWebAppObjects: [WebApp] { allWebApps.filter { selectedWebApps.contains($0.id) } }

    func toggle(_ web: WebApp) {
        if selectedWebApps.contains(web.id) { selectedWebApps.remove(web.id) }
        else { selectedWebApps.insert(web.id) }
    }

    func addCustomWebApp(name: String, url: String) {
        var clean = url.trimmingCharacters(in: .whitespaces)
        if !clean.lowercased().hasPrefix("http") { clean = "https://" + clean }
        let app = WebApp.custom(name: name.trimmingCharacters(in: .whitespaces), url: clean)
        guard !allWebApps.contains(where: { $0.id == app.id }) else { return }
        customWebApps.append(app)
        selectedWebApps.insert(app.id)
        persistCustomWebApps()
    }

    func removeCustomWebApp(_ app: WebApp) {
        customWebApps.removeAll { $0.id == app.id }
        selectedWebApps.remove(app.id)
        persistCustomWebApps()
    }

    private var customWebAppsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSetup", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("webapps.json")
    }

    private func loadCustomWebApps() {
        guard let d = try? Data(contentsOf: customWebAppsURL),
              let list = try? JSONDecoder().decode([WebApp].self, from: d) else { return }
        customWebApps = list
    }

    private func persistCustomWebApps() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(customWebApps) { try? d.write(to: customWebAppsURL, options: .atomic) }
    }

    /// How many separate password prompts this selection will produce.
    var authPromptCount: Int {
        var n = 0
        let needsRootApp = selectedAppObjects.contains {
            $0.source.needsRoot || $0.fallback?.needsRoot == true || $0.isBrewPackage || $0.needsTerminal
        }
        if needsRootApp || !selectedSystemUpdates.isEmpty { n += 1 }
        let needsBrew = selectedAppObjects.contains { $0.source.kind == .brew || $0.fallback?.kind == .brew }
        if needsBrew && !brewPresent { n += 1 }
        return n
    }

    var selectionNeedsAuth: Bool {
        selectedAppObjects.contains { $0.needsRoot }
            || (selectedAppObjects.contains { $0.source.kind == .brew || $0.fallback?.kind == .brew }
                && installedBundleIDs.isEmpty == false && !brewPresent)
    }

    var brewPresent: Bool {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    var filtersActive: Bool {
        !search.isEmpty || category != nil || !activeTags.isEmpty
            || !licenseFilter.isEmpty || !sourceFilter.isEmpty || hideInstalled
            || hideAdminRequired
    }

    // MARK: - Selection helpers

    func toggle(_ app: CatalogApp) {
        if selectedApps.contains(app.id) { selectedApps.remove(app.id) }
        else { selectedApps.insert(app.id) }
    }

    func toggle(_ tweak: DefaultTweak) {
        if selectedTweaks.contains(tweak.id) { selectedTweaks.remove(tweak.id) }
        else { selectedTweaks.insert(tweak.id) }
    }

    func selectAllVisible() { selectedApps.formUnion(filteredApps.map(\.id)) }
    func deselectAllVisible() { selectedApps.subtract(filteredApps.map(\.id)) }
    func clearSelection() {
        selectedApps.removeAll(); selectedTweaks.removeAll()
        selectedWebApps.removeAll(); selectedSystemUpdates.removeAll()
    }

    func selectTag(_ tag: String) {
        selectedApps.formUnion(allApps.filter { $0.tags.contains(tag) }.map(\.id))
    }

    func selectRecommendedTweaks() {
        selectedTweaks.formUnion((catalog?.systemDefaults ?? []).filter(\.recommended).map(\.id))
    }

    func resetFilters() {
        search = ""; category = nil; activeTags = []
        licenseFilter = []; sourceFilter = []; hideInstalled = false
        hideAdminRequired = false
    }

    // MARK: - Profiles

    func apply(_ profile: Profile) {
        let known = Set(allApps.map(\.id))
        let knownTweaks = Set((catalog?.systemDefaults ?? []).map(\.id))
        selectedApps = Set(profile.appIDs).intersection(known)
        selectedTweaks = Set(profile.tweakIDs).intersection(knownTweaks)
        let knownWeb = Set(allWebApps.map(\.id))
        selectedWebApps = Set(profile.webAppIDs).intersection(knownWeb)
        profile.options?.apply(to: &options)
        // Custom web apps travel with the profile, so an imported one still works.
        for w in profile.customWebApps where !allWebApps.contains(where: { $0.id == w.id }) {
            customWebApps.append(w)
            selectedWebApps.insert(w.id)
        }
        persistCustomWebApps()
    }

    func currentProfile(named name: String) -> Profile {
        Profile(name: name,
                appIDs: selectedApps.sorted(),
                tweakIDs: selectedTweaks.sorted(),
                webAppIDs: selectedWebApps.sorted(),
                customWebApps: customWebApps.filter { selectedWebApps.contains($0.id) },
                options: Profile.SavedOptions(options))
    }

    /// Entries in a profile that this catalogue no longer knows about.
    func unknownEntries(in profile: Profile) -> [String] {
        let known = Set(allApps.map(\.id))
            .union(Set((catalog?.systemDefaults ?? []).map(\.id)))
            .union(Set(allWebApps.map(\.id)))
            .union(Set(profile.customWebApps.map(\.id)))
        return (profile.appIDs + profile.tweakIDs + profile.webAppIDs).filter { !known.contains($0) }
    }

    // MARK: - Installed detection

    func isInstalled(_ app: CatalogApp) -> Bool {
        if let b = app.bundleId, installedBundleIDs.contains(b) { return true }
        return false
    }

    /// Reads every application bundle once, which is far faster and more
    /// reliable than shelling out to mdfind per app. System applications are
    /// skipped — they are not ours to remove.
    func scanInstalled() async {
        let dirs = ["/Applications", "\(NSHomeDirectory())/Applications", "/Applications/Utilities"]
        struct Raw: Sendable { let name: String; let bundleID: String; let version: String; let path: String }

        let raw: [Raw] = await Task.detached(priority: .utility) {
            var out: [Raw] = []
            let fm = FileManager.default
            for dir in dirs {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where entry.hasSuffix(".app") {
                    let path = "\(dir)/\(entry)"
                    let plist = "\(path)/Contents/Info.plist"
                    let d = NSDictionary(contentsOfFile: plist)
                    let bundle = (d?["CFBundleIdentifier"] as? String) ?? ""
                    let version = (d?["CFBundleShortVersionString"] as? String)
                        ?? (d?["CFBundleVersion"] as? String) ?? "—"
                    let name = String(entry.dropLast(4))
                    out.append(Raw(name: name, bundleID: bundle, version: version, path: path))
                }
            }
            return out
        }.value

        installedBundleIDs = Set(raw.map(\.bundleID).filter { !$0.isEmpty })

        let byBundle = Dictionary(allApps.compactMap { app -> (String, String)? in
            guard let b = app.bundleId else { return nil }
            return (b, app.id)
        }, uniquingKeysWith: { a, _ in a })

        installedEntries = raw.map { r in
            InstalledEntry(id: r.path, name: r.name, bundleID: r.bundleID,
                           version: r.version, path: r.path,
                           catalogID: byBundle[r.bundleID])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What the Installed pane shows, after its own search and filter.
    var visibleInstalled: [InstalledEntry] {
        let needle = installedSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return installedEntries.filter { e in
            if !showNonCatalogueApps && !e.inCatalogue { return false }
            if !needle.isEmpty {
                return e.name.lowercased().contains(needle) || e.bundleID.lowercased().contains(needle)
            }
            return true
        }
    }

    var installedFromCatalogue: Int { installedEntries.filter(\.inCatalogue).count }

    func uninstallTarget(for entry: InstalledEntry) -> UninstallTarget {
        if let cid = entry.catalogID, let app = allApps.first(where: { $0.id == cid }) {
            return UninstallTarget(app)
        }
        return UninstallTarget(bundleName: entry.name, bundleID: entry.bundleID)
    }

    // MARK: - Script

    func buildScript() -> String {
        ScriptGenerator.build(apps: selectedAppObjects,
                              tweaks: selectedTweakObjects,
                              webApps: selectedWebAppObjects,
                              browser: browser,
                              options: options,
                              arch: arch)
    }
}
