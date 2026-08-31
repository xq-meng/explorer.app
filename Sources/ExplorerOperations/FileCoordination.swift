import Foundation

/// The mutation intent passed to ``FileCoordinationClient``. Keeping the
/// Foundation option set behind this type makes coordination behavior easy to
/// record in tests without constructing an `NSFileCoordinator`.
enum CoordinatedWriteIntent: Sendable, Equatable {
    case createOrModify
    case delete
    case move
}

/// Coordinates access to file URLs that may also be managed by Finder,
/// document apps, iCloud, or another File Provider client.
protocol FileCoordinationClient: Sendable {
    func coordinateWriting(
        at url: URL,
        intent: CoordinatedWriteIntent,
        accessor: (URL) throws -> Void
    ) throws

    func coordinateReading(
        at source: URL,
        writingAt destination: URL,
        destinationIntent: CoordinatedWriteIntent,
        accessor: (URL, URL) throws -> Void
    ) throws

    func coordinateMoving(
        from source: URL,
        to destination: URL,
        accessor: (URL, URL) throws -> Void
    ) throws
}

/// Production coordination backed by `NSFileCoordinator`. A fresh
/// coordinator is used for each request so this value remains safely
/// shareable between the operation actor and detached copy tasks.
struct SystemFileCoordinationClient: FileCoordinationClient, Sendable {
    init() {}

    func coordinateWriting(
        at url: URL,
        intent: CoordinatedWriteIntent,
        accessor: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let outcome = CoordinationOutcome()
        coordinator.coordinate(
            writingItemAt: url,
            options: writingOptions(for: intent),
            error: &coordinationError
        ) { coordinatedURL in
            outcome.capture { try accessor(coordinatedURL) }
        }
        try outcome.get()
        if let coordinationError { throw coordinationError }
    }

    func coordinateReading(
        at source: URL,
        writingAt destination: URL,
        destinationIntent: CoordinatedWriteIntent,
        accessor: (URL, URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let outcome = CoordinationOutcome()
        coordinator.coordinate(
            readingItemAt: source,
            options: .withoutChanges,
            writingItemAt: destination,
            options: writingOptions(for: destinationIntent),
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            outcome.capture { try accessor(coordinatedSource, coordinatedDestination) }
        }
        try outcome.get()
        if let coordinationError { throw coordinationError }
    }

    func coordinateMoving(
        from source: URL,
        to destination: URL,
        accessor: (URL, URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        let outcome = CoordinationOutcome()
        coordinator.coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            outcome.capture { try accessor(coordinatedSource, coordinatedDestination) }
        }
        try outcome.get()
        if let coordinationError { throw coordinationError }
    }

    private func writingOptions(for intent: CoordinatedWriteIntent) -> NSFileCoordinator.WritingOptions {
        switch intent {
        case .createOrModify: []
        case .delete: .forDeleting
        case .move: .forMoving
        }
    }
}

private final class CoordinationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func capture(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }

    func get() throws {
        lock.lock()
        let error = error
        lock.unlock()
        if let error { throw error }
    }
}
