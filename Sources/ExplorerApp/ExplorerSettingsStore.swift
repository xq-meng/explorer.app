import AppKit
import ExplorerUI

@MainActor
final class ExplorerSettingsStore {
    struct TabSession {
        let locations: [URL]
        let selectedIndex: Int
    }

    private enum Key {
        static let frame = "Explorer.window.frame"
        static let sidebarWidth = "Explorer.window.sidebarWidth"
        static let viewMode = "Explorer.browser.viewMode"
        static let showsPreview = "Explorer.browser.showsPreview"
        static let tabPaths = "Explorer.session.tabPaths"
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
        let paths = defaults.stringArray(forKey: Key.tabPaths) ?? []
        var seen = Set<URL>()
        let locations = paths.prefix(limit).compactMap { path -> URL? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }
        return TabSession(locations: locations, selectedIndex: defaults.integer(forKey: Key.selectedTabIndex))
    }

    func saveTabSession(locations: [URL], selectedIndex: Int) {
        guard !locations.isEmpty else { return }
        defaults.set(locations.map(\.path), forKey: Key.tabPaths)
        defaults.set(max(0, selectedIndex), forKey: Key.selectedTabIndex)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
