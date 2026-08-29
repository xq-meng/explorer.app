import ExplorerCore
import Foundation

/// The single source of truth for the rows currently presented by a tab.
enum ExplorerTabContent {
    case home
    case directory(DirectorySnapshot, overlay: [FileItem])
    case search(base: DirectorySnapshot, overlay: [FileItem], query: String, items: [FileItem], isComplete: Bool)

    var visibleItems: [FileItem] {
        switch self {
        case .home:
            return []
        case let .directory(snapshot, overlay):
            return Self.merging(snapshot.items, overlay: overlay)
        case let .search(_, _, _, items, _):
            return items
        }
    }

    var baseSnapshot: DirectorySnapshot? {
        switch self {
        case .home:
            return nil
        case let .directory(snapshot, _), let .search(snapshot, _, _, _, _):
            return snapshot
        }
    }

    var overlayItems: [FileItem] {
        switch self {
        case .home:
            return []
        case let .directory(_, overlay), let .search(_, overlay, _, _, _):
            return overlay
        }
    }

    var overlayDirectoryURLs: [URL] {
        overlayItems.filter { $0.kind == .directory }.map(\.url)
    }

    private static func merging(_ items: [FileItem], overlay: [FileItem]) -> [FileItem] {
        var seen = Set(items.map(\.url.standardizedFileURL))
        var merged = items
        for item in overlay where seen.insert(item.url.standardizedFileURL).inserted {
            merged.append(item)
        }
        return merged
    }
}

struct ExplorerTabContentState {
    private(set) var content = ExplorerTabContent.home

    var visibleItems: [FileItem] { content.visibleItems }
    var baseSnapshot: DirectorySnapshot? { content.baseSnapshot }
    var overlayItems: [FileItem] { content.overlayItems }
    var overlayDirectoryURLs: [URL] { content.overlayDirectoryURLs }

    mutating func showHome() {
        content = .home
    }

    mutating func showDirectory(_ snapshot: DirectorySnapshot, overlay: [FileItem] = []) {
        content = .directory(snapshot, overlay: overlay)
    }

    @discardableResult
    mutating func showSearchResults(
        _ items: [FileItem],
        query: String,
        isComplete: Bool
    ) -> Bool {
        guard let base = content.baseSnapshot else { return false }
        content = .search(
            base: base,
            overlay: content.overlayItems,
            query: query,
            items: items,
            isComplete: isComplete
        )
        return true
    }

    mutating func restoreDirectory() {
        guard let base = content.baseSnapshot else { return }
        content = .directory(base, overlay: content.overlayItems)
    }

    func selectedItems(for urls: Set<URL>) -> [FileItem] {
        visibleItems.filter { urls.contains($0.url) }
    }
}
