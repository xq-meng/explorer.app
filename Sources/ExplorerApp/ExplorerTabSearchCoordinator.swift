import ExplorerBrowsing
import ExplorerCore
import Foundation

/// Owns the lifecycle of one tab's staged directory search.
///
/// Immediate results stay responsive while the subtree query continues, and
/// generation tracking prevents an older task from updating a newer query.
@MainActor
final class ExplorerTabSearchCoordinator {
    var onResults: (([FileItem], String, Bool) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let service: SearchService
    private var task: Task<Void, Never>?
    private var generation: UInt = 0
    private var activeRoot: URL?

    init(service: SearchService = SearchService()) {
        self.service = service
    }

    deinit {
        task?.cancel()
    }

    func search(
        snapshot: DirectorySnapshot,
        text: String,
        includesHiddenFiles: Bool
    ) {
        generation &+= 1
        let generation = generation
        task?.cancel()

        let query = SearchQuery(text: text, includesHiddenFiles: includesHiddenFiles)
        let root = snapshot.directoryURL
        activeRoot = root
        let service = service
        task = Task { [weak self] in
            do {
                let immediate = try await service.filter(snapshot, matching: query)
                guard let self, self.isCurrent(generation, root: root) else { return }
                self.onResults?(immediate, text, immediate.count >= query.maximumResults)

                guard immediate.count < query.maximumResults else { return }
                let subtree = try await service.searchSubtree(at: root, matching: query)
                guard self.isCurrent(generation, root: root) else { return }
                self.onResults?(Self.merge(immediate, with: subtree), text, true)
            } catch is CancellationError {
            } catch SearchServiceError.cancelled {
            } catch {
                guard let self, self.isCurrent(generation, root: root) else { return }
                self.onFailure?(error)
            }
        }
    }

    func cancel() {
        generation &+= 1
        activeRoot = nil
        task?.cancel()
        task = nil
    }

    private func isCurrent(_ generation: UInt, root: URL) -> Bool {
        !Task.isCancelled && generation == self.generation && activeRoot == root
    }

    private static func merge(_ immediate: [FileItem], with subtree: [FileItem]) -> [FileItem] {
        var seen = Set(immediate.map { $0.url.standardizedFileURL })
        var merged = immediate
        for item in subtree where seen.insert(item.url.standardizedFileURL).inserted {
            merged.append(item)
        }
        return merged.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }
}
