import ExplorerBrowsing
import Foundation

/// Deduplicates and cancels visible-item thumbnail requests for one tab.
@MainActor
final class ExplorerTabThumbnailCoordinator {
    var onThumbnail: ((ThumbnailImage, URL) -> Void)?

    private let service: ThumbnailService
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var requestIDs: [URL: UUID] = [:]

    init(service: ThumbnailService = ThumbnailService()) {
        self.service = service
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    func request(_ url: URL, scale: Double) {
        let target = url.standardizedFileURL
        guard tasks[target] == nil else { return }

        let requestID = UUID()
        requestIDs[target] = requestID
        let service = service
        tasks[target] = Task { [weak self] in
            defer { self?.finish(target, requestID: requestID) }
            do {
                let thumbnail = try await service.thumbnail(for: ThumbnailRequest(
                    url: target,
                    maximumPixelSize: 160,
                    scale: scale
                ))
                guard !Task.isCancelled, let self else { return }
                self.onThumbnail?(thumbnail, target)
            } catch {
                // The file view retains its system icon when thumbnailing is
                // cancelled or Quick Look cannot produce a representation.
            }
        }
    }

    func cancel(_ url: URL) {
        let target = url.standardizedFileURL
        requestIDs[target] = nil
        tasks.removeValue(forKey: target)?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        requestIDs.removeAll()
    }

    private func finish(_ url: URL, requestID: UUID) {
        guard requestIDs[url] == requestID else { return }
        tasks[url] = nil
        requestIDs[url] = nil
    }
}
