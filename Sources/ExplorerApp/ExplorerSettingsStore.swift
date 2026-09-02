import AppKit
import ExplorerUI

@MainActor
final class ExplorerSettingsStore {
    private enum Key {
        static let frame = "Explorer.window.frame"
        // v2 intentionally resets widths persisted while divider dragging was
        // constrained incorrectly. Subsequent changes continue to persist.
        static let sidebarWidth = "Explorer.window.sidebarWidth.v2"
        static let viewMode = "Explorer.browser.viewMode"
        static let showsPreview = "Explorer.browser.showsPreview"
        static let showsHiddenFiles = "Explorer.browser.showsHiddenFiles"
        static let favorites = "Explorer.sidebar.favorites"
        static let dualPaneEnabled = "Explorer.browser.dualPaneEnabled"
        static let dualPaneRestorationState = "Explorer.browser.dualPaneRestorationState.v1"
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

    var dualPaneEnabled: Bool {
        get { defaults.object(forKey: Key.dualPaneEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.dualPaneEnabled) }
    }

    var dualPaneRestorationState: ExplorerDualPaneRestorationState? {
        get {
            guard let data = defaults.data(forKey: Key.dualPaneRestorationState),
                  let state = try? JSONDecoder().decode(
                    ExplorerDualPaneRestorationState.self,
                    from: data
                  ),
                  state.isSupported else { return nil }
            return state
        }
        set {
            guard let newValue,
                  let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Key.dualPaneRestorationState)
                return
            }
            defaults.set(data, forKey: Key.dualPaneRestorationState)
        }
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

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
