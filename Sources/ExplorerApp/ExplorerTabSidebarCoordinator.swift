import ExplorerBrowsing
import ExplorerCore
import ExplorerUI
import Foundation

@MainActor
final class ExplorerTabSidebarCoordinator {
    var onFolders: (([BrowserSidebarLocation], URL) -> Void)?
    var onFailure: ((String) -> Void)?

    private let loader = DirectoryLoader()
    private var tasks: [URL: Task<Void, Never>] = [:]

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func loadChildren(of parentURL: URL, showsHiddenFiles: Bool) {
        let parent = parentURL.standardizedFileURL
        tasks[parent]?.cancel()
        let loader = loader
        let options = DirectoryLoadOptions(showsHiddenFiles: showsHiddenFiles)
        tasks[parent] = Task { [weak self] in
            defer { self?.tasks[parent] = nil }
            do {
                let snapshot = try await loader.load(parent, options: options)
                guard !Task.isCancelled, let self else { return }
                self.onFolders?(Self.folders(from: snapshot), parent)
            } catch is CancellationError {
            } catch FileProviderError.cancelled {
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.onFolders?([], parent)
                self.onFailure?(
                    "Unable to expand \(parent.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    static func folders(from snapshot: DirectorySnapshot) -> [BrowserSidebarLocation] {
        snapshot.items.compactMap { item in
            guard item.kind == .directory, !item.isPackage, !item.isSymbolicLink else { return nil }
            return BrowserSidebarLocation(title: item.name, url: item.url)
        }
    }
}
