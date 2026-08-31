import Foundation

public enum FileOperationQueueState: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

public enum FileOperationQueueError: Error, LocalizedError, Equatable, Sendable {
    case unknownOperation(UUID)

    public var errorDescription: String? {
        switch self {
        case .unknownOperation(let id): return "Unknown operation: \(id.uuidString)"
        }
    }
}

public struct FileOperationQueueSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let operation: FileOperation
    public let state: FileOperationQueueState
    public let result: FileOperationResult?
    public let errorDescription: String?

    public init(id: UUID, operation: FileOperation, state: FileOperationQueueState,
                result: FileOperationResult? = nil, errorDescription: String? = nil) {
        self.id = id
        self.operation = operation
        self.state = state
        self.result = result
        self.errorDescription = errorDescription
    }
}

public struct FileOperationQueueProgress: Sendable, Equatable {
    public let id: UUID
    public let progress: FileOperationProgress

    public init(id: UUID, progress: FileOperationProgress) {
        self.id = id
        self.progress = progress
    }
}

public enum FileOperationQueueEvent: Sendable, Equatable {
    case stateChanged(FileOperationQueueSnapshot)
    case progress(FileOperationQueueProgress)
}

/// A serial operation coordinator. Jobs are started in submission order and
/// one failed or cancelled job never prevents the next queued job from running.
public actor FileOperationQueue {
    public nonisolated let events: AsyncStream<FileOperationQueueEvent>

    private let engine: FileOperationEngine
    private var eventContinuation: AsyncStream<FileOperationQueueEvent>.Continuation
    private var jobs: [UUID: FileOperationQueueSnapshot] = [:]
    private var order: [UUID] = []
    private var runningID: UUID?
    private var runningTask: Task<Void, Never>?
    private var waiters: [UUID: [CheckedContinuation<FileOperationResult, Error>]] = [:]
    private var conflictResolvers: [UUID: any FileConflictResolving] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(engine: FileOperationEngine = FileOperationEngine(), bufferSize: Int = 256) {
        let size = max(1, bufferSize)
        let pair = AsyncStream<FileOperationQueueEvent>.makeStream(
            of: FileOperationQueueEvent.self,
            bufferingPolicy: .bufferingNewest(size)
        )
        self.events = pair.stream
        self.eventContinuation = pair.continuation
        self.engine = engine
    }

    deinit { eventContinuation.finish() }

    @discardableResult
    public func submit(
        _ operation: FileOperation,
        conflictResolver: (any FileConflictResolving)? = nil
    ) -> UUID {
        let id = UUID()
        let snapshot = FileOperationQueueSnapshot(id: id, operation: operation, state: .queued)
        jobs[id] = snapshot
        order.append(id)
        conflictResolvers[id] = conflictResolver
        emit(.stateChanged(snapshot))
        startNextIfNeeded()
        return id
    }

    public func snapshot(for id: UUID) -> FileOperationQueueSnapshot? { jobs[id] }

    public func snapshots() -> [FileOperationQueueSnapshot] {
        order.compactMap { jobs[$0] }
    }

    public func hasActiveOperations() -> Bool {
        jobs.values.contains { $0.state == .queued || $0.state == .running }
    }

    /// Requests cancellation for every queued or running operation. Running
    /// work remains active until the underlying file call observes
    /// cancellation and unwinds.
    public func cancelAll() {
        let activeIDs = order.filter {
            guard let state = jobs[$0]?.state else { return false }
            return state == .queued || state == .running
        }
        for id in activeIDs { _ = cancel(id) }
        resumeIdleWaitersIfNeeded()
    }

    public func waitUntilIdle() async {
        guard hasActiveOperations() else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Cancels a queued item immediately, or asks the running engine task to
    /// cancel at its next item boundary.
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard let snapshot = jobs[id] else { return false }
        switch snapshot.state {
        case .queued:
            let cancelled = FileOperationQueueSnapshot(id: id, operation: snapshot.operation, state: .cancelled,
                                                       errorDescription: FileOperationError.cancelled.localizedDescription)
            jobs[id] = cancelled
            emit(.stateChanged(cancelled))
            finishWaiters(for: id, with: .failure(FileOperationError.cancelled))
            conflictResolvers[id] = nil
            return true
        case .running:
            guard runningID == id else { return false }
            runningTask?.cancel()
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    public func result(for id: UUID) async throws -> FileOperationResult {
        guard let snapshot = jobs[id] else {
            throw FileOperationQueueError.unknownOperation(id)
        }
        switch snapshot.state {
        case .completed:
            if let result = snapshot.result { return result }
            throw FileOperationError.underlying("Completed operation has no result")
        case .failed:
            throw FileOperationError.underlying(snapshot.errorDescription ?? "Operation failed")
        case .cancelled:
            throw FileOperationError.cancelled
        case .queued, .running:
            return try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(continuation)
            }
        }
    }

    private func startNextIfNeeded() {
        guard runningID == nil else { return }
        guard let id = order.first(where: { jobs[$0]?.state == .queued }),
              let snapshot = jobs[id] else { return }
        runningID = id
        let running = FileOperationQueueSnapshot(id: id, operation: snapshot.operation, state: .running)
        jobs[id] = running
        emit(.stateChanged(running))
        let operation = snapshot.operation
        let resolver = conflictResolvers[id]
        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.execute(
                    operation,
                    conflictResolver: resolver,
                    asyncProgress: { [weak self] progress in
                        await self?.receive(progress: progress, for: id)
                    }
                )
                await self.finish(id: id, result: result, error: nil)
            } catch {
                await self.finish(id: id, result: nil, error: error)
            }
        }
    }

    private func receive(progress: FileOperationProgress, for id: UUID) {
        guard jobs[id]?.state == .running else { return }
        emit(.progress(FileOperationQueueProgress(
            id: id,
            progress: FileOperationProgress(
                operationID: id,
                kind: progress.kind,
                completedItems: progress.completedItems,
                totalItems: progress.totalItems,
                currentItem: progress.currentItem,
                completedBytes: progress.completedBytes,
                totalBytes: progress.totalBytes
            )
        )))
    }

    private func finish(id: UUID, result: FileOperationResult?, error: Error?) {
        guard let snapshot = jobs[id], snapshot.state == .running else { return }
        let state: FileOperationQueueState
        let description: String?
        if let error {
            state = (error as? FileOperationError) == .cancelled ? .cancelled : .failed
            description = error.localizedDescription
        } else {
            state = .completed
            description = nil
        }
        let stableResult = result.map { FileOperationResult(operationID: id, kind: $0.kind, items: $0.items) }
        let final = FileOperationQueueSnapshot(id: id, operation: snapshot.operation, state: state,
                                               result: stableResult, errorDescription: description)
        jobs[id] = final
        conflictResolvers[id] = nil
        emit(.stateChanged(final))
        if let stableResult {
            finishWaiters(for: id, with: .success(stableResult))
        } else {
            finishWaiters(for: id, with: .failure(error ?? FileOperationError.underlying("Operation failed")))
        }
        runningID = nil
        runningTask = nil
        startNextIfNeeded()
        resumeIdleWaitersIfNeeded()
    }

    private func finishWaiters(for id: UUID, with result: Result<FileOperationResult, Error>) {
        guard let continuations = waiters.removeValue(forKey: id) else { return }
        for continuation in continuations { continuation.resume(with: result) }
    }

    private func emit(_ event: FileOperationQueueEvent) { eventContinuation.yield(event) }

    private func resumeIdleWaitersIfNeeded() {
        guard !hasActiveOperations(), !idleWaiters.isEmpty else { return }
        let continuations = idleWaiters
        idleWaiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}
