import AppKit
import ExplorerUI

@MainActor
final class ExplorerSettingsStore {
    struct TabState: Codable, Equatable {
        let url: URL
        let viewMode: BrowserViewMode
        let sortDescriptor: BrowserSortDescriptor

        init(
            url: URL,
            viewMode: BrowserViewMode = .details,
            sortDescriptor: BrowserSortDescriptor = .nameAscending
        ) {
            self.url = url.standardizedFileURL
            self.viewMode = viewMode
            self.sortDescriptor = sortDescriptor
        }
    }

    struct TabSession {
        let tabs: [TabState]
        let selectedIndex: Int
    }

    private enum Key {
        static let frame = "Explorer.window.frame"
        static let sidebarWidth = "Explorer.window.sidebarWidth"
        static let viewMode = "Explorer.browser.viewMode"
        static let showsPreview = "Explorer.browser.showsPreview"
        static let showsHiddenFiles = "Explorer.browser.showsHiddenFiles"
        static let tabPaths = "Explorer.session.tabPaths"
        static let tabStates = "Explorer.session.tabStates"
        static let selectedTabIndex = "Explorer.session.selectedTabIndex"
        static let favorites = "Explorer.sidebar.favorites"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var windowFrame: NSRect? {
        get { defaults.string(forKey: Key.frame).map(NSRectFromString) }
        set { newValue.map { defaults.set(NSStringFromRect($0), forKey: Key.frame) } }
    }

    var sidebarWidth: CGFloat? {
        get { (defaults.object(forKey: Key.sidebarWidth) as? NSNumber).map { CGFloat($0.doubleValue) } }
        set { newValue.map { defaults.set(Double($0), forKey: Key.sidebarWidth) } }
    }

    var viewMode: BrowserViewMode {
        get { defaults.string(forKey: Key.viewMode).flatMap(BrowserViewMode.init(rawValue:)) ?? .details }
        set { defaults.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    var showsPreview: Bool {
        get { defaults.object(forKey: Key.showsPreview) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showsPreview) }
    }

    var showsHiddenFiles: Bool {
        get { defaults.object(forKey: Key.showsHiddenFiles) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.showsHiddenFiles) }
    }

    var favoriteURLs: [URL] {
        (defaults.stringArray(forKey: Key.favorites) ?? []).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    func addFavorite(_ url: URL) {
        var paths = favoriteURLs.map(\.path)
        paths.append(url.standardizedFileURL.path)
        defaults.set(unique(paths), forKey: Key.favorites)
    }

    func removeFavorite(_ url: URL) {
        let target = url.standardizedFileURL
        defaults.set(favoriteURLs.filter { $0 != target }.map(\.path), forKey: Key.favorites)
    }

    func restoredTabSession(limit: Int = 12) -> TabSession {
        if let data = defaults.data(forKey: Key.tabStates),
           let decoded = try? JSONDecoder().decode([TabState].self, from: data) {
            return TabSession(
                tabs: Array(decoded.prefix(limit)),
                selectedIndex: defaults.integer(forKey: Key.selectedTabIndex)
            )
        }

        let paths = defaults.stringArray(forKey: Key.tabPaths) ?? []
        var seen = Set<URL>()
        let tabs = paths.prefix(limit).compactMap { path -> TabState? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(url).inserted ? TabState(url: url, viewMode: viewMode) : nil
        }
        return TabSession(tabs: tabs, selectedIndex: defaults.integer(forKey: Key.selectedTabIndex))
    }

    func saveTabSession(tabs: [TabState], selectedIndex: Int) {
        guard !tabs.isEmpty else { return }
        if let data = try? JSONEncoder().encode(tabs) {
            defaults.set(data, forKey: Key.tabStates)
        }
        defaults.set(tabs.map(\.url.path), forKey: Key.tabPaths)
        defaults.set(max(0, selectedIndex), forKey: Key.selectedTabIndex)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
