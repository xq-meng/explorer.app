import AppKit
import ExplorerUI

enum FilePromiseDropError: Error, LocalizedError {
    case empty
    case timedOut

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The dropped files could not be received."
        case .timedOut:
            return "Timed out while receiving dropped files."
        }
    }
}

enum FilePromiseDropCoordinator {
    static func makeStagingDirectory(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let url = temporaryDirectory
            .appendingPathComponent("ExplorerDrops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fulfills pasteboard file promises into `directory`.
    ///
    /// The `receivePromisedFiles` call itself must start on the main thread.
    /// AppKit invokes the reader on `operationQueue`, which is not the main
    /// actor — the reader therefore has to be a nonisolated `@Sendable`
    /// closure. A MainActor-isolated reader traps with `SIGTRAP` /
    /// `_dispatch_assert_queue_fail` as soon as Safari/Mail delivers the file.
    @MainActor
    static func receivePromisedFiles(
        _ receivers: [NSFilePromiseReceiver],
        into directory: URL,
        operationQueue: OperationQueue
    ) async throws -> [URL] {
        guard !receivers.isEmpty else { throw FilePromiseDropError.empty }
        operationQueue.maxConcurrentOperationCount = 1
        let expected = max(receivers.reduce(0) { $0 + $1.fileNames.count }, receivers.count)
        let state = ReceiveState(expected: expected)
        state.retain(receivers)

        return try await withCheckedThrowingContinuation { continuation in
            state.attach(continuation)
            let reader = makeReader(state)
            for receiver in receivers {
                receiver.receivePromisedFiles(
                    atDestination: directory,
                    options: [:],
                    operationQueue: operationQueue,
                    reader: reader
                )
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 60) {
                state.timeout()
            }
        }
    }

    /// Built outside the MainActor method so the compiler cannot isolate it to
    /// the main actor. AppKit calls this on `operationQueue`.
    private nonisolated static func makeReader(
        _ state: ReceiveState
    ) -> @Sendable (URL, (any Error)?) -> Void {
        { url, error in
            state.note(url: url, error: error)
        }
    }
}

private final class ReceiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []
    private var firstError: Error?
    private var continuation: CheckedContinuation<[URL], Error>?
    private var receivers: [NSFilePromiseReceiver] = []

    init(expected: Int) {
        remaining = max(expected, 1)
    }

    func retain(_ receivers: [NSFilePromiseReceiver]) {
        lock.lock()
        self.receivers = receivers
        lock.unlock()
    }

    func attach(_ continuation: CheckedContinuation<[URL], Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func note(url: URL, error: Error?) {
        lock.lock()
        if let error {
            if firstError == nil { firstError = error }
        } else {
            urls.append(url)
        }
        remaining -= 1
        let pending = remaining <= 0 ? takePendingLocked(timedOut: false) : nil
        lock.unlock()
        pending?.resume()
    }

    func timeout() {
        lock.lock()
        let pending = takePendingLocked(timedOut: true)
        lock.unlock()
        pending?.resume()
    }

    private func takePendingLocked(timedOut: Bool) -> PendingResume? {
        guard let continuation else { return nil }
        self.continuation = nil
        receivers = []
        if urls.isEmpty {
            return PendingResume(continuation: continuation, result: .failure(
                timedOut ? FilePromiseDropError.timedOut : (firstError ?? FilePromiseDropError.empty)
            ))
        }
        return PendingResume(continuation: continuation, result: .success(urls))
    }
}

private struct PendingResume {
    let continuation: CheckedContinuation<[URL], Error>
    let result: Result<[URL], Error>

    func resume() {
        switch result {
        case let .success(urls):
            continuation.resume(returning: urls)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
