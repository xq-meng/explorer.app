import Foundation

/// Abstraction over Spotlight so ``SearchService`` can be tested without a live index.
public protocol SpotlightSearching: Sendable {
    func itemURLs(matching query: SearchQuery, scopedTo root: URL) async throws -> [URL]
}

/// Runs a scoped ``NSMetadataQuery`` on a serial operation queue.
///
/// `NSMetadataQuery.start()` must run on that queue (or the main thread). The
/// client waits for the initial gathering phase, then stops so later live-update
/// notifications cannot resume a finished search.
public struct SpotlightMetadataClient: SpotlightSearching {
    public init() {}

    public func itemURLs(matching query: SearchQuery, scopedTo root: URL) async throws -> [URL] {
        try await SpotlightMetadataSession().search(matching: query, scopedTo: root)
    }
}

enum SpotlightMetadataPredicate {
    static func likePattern(for text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "[", with: "\\[")
        return "*\(escaped)*"
    }

    static func make(for query: SearchQuery) -> NSPredicate {
        let pattern = likePattern(for: query.text)
        if query.caseSensitive {
            return NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, pattern)
        }
        return NSPredicate(format: "%K LIKE[c] %@", NSMetadataItemFSNameKey, pattern)
    }
}

private struct UnsafeBox<T>: @unchecked Sendable {
    let value: T
}

private final class SpotlightMetadataSession: @unchecked Sendable {
    private let lock = NSLock()
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.explorer.spotlight-query"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var continuation: CheckedContinuation<[URL], Error>?
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    func search(matching query: SearchQuery, scopedTo root: URL) async throws -> [URL] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.begin(query: query, root: root, continuation: continuation)
            }
        } onCancel: {
            self.finish(.failure(SearchServiceError.cancelled))
        }
    }

    private func begin(
        query: SearchQuery,
        root: URL,
        continuation: CheckedContinuation<[URL], Error>
    ) {
        let metadataQuery = NSMetadataQuery()
        metadataQuery.operationQueue = operationQueue
        metadataQuery.predicate = SpotlightMetadataPredicate.make(for: query)
        metadataQuery.searchScopes = [root]
        metadataQuery.valueListAttributes = [NSMetadataItemPathKey]

        let finished = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery,
            queue: operationQueue
        ) { [weak self] _ in
            self?.completeGathering()
        }

        lock.lock()
        self.continuation = continuation
        self.query = metadataQuery
        self.observers = [finished]
        lock.unlock()

        let queryBox = UnsafeBox(value: metadataQuery)
        let sessionBox = UnsafeBox(value: self)
        operationQueue.addOperation {
            guard queryBox.value.start() else {
                sessionBox.value.finish(.failure(SearchServiceError.unavailable(root, code: 0)))
                return
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 60) {
                sessionBox.value.finish(.failure(SearchServiceError.unavailable(root, code: NSURLErrorTimedOut)))
            }
        }
    }

    private func completeGathering() {
        lock.lock()
        let metadataQuery = query
        lock.unlock()
        guard let metadataQuery else { return }

        metadataQuery.disableUpdates()
        var urls: [URL] = []
        urls.reserveCapacity(metadataQuery.resultCount)
        metadataQuery.enumerateResults { item, _, _ in
            guard let item = item as? NSMetadataItem else { return }
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: path))
            } else if let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                urls.append(url)
            }
        }
        finish(.success(urls))
    }

    private func finish(_ result: Result<[URL], Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let metadataQuery = query
        let observers = self.observers
        self.observers = []
        query = nil
        lock.unlock()

        guard let continuation else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        if let metadataQuery {
            let queryBox = UnsafeBox(value: metadataQuery)
            operationQueue.addOperation {
                queryBox.value.stop()
            }
        }
        switch result {
        case let .success(urls):
            continuation.resume(returning: urls)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
