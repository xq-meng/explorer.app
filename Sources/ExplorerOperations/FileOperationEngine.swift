import Foundation

/// The small file-system surface used by the operation engine.  Keeping this
/// behind a protocol makes tests deterministic and keeps UI code away from
/// ``FileManager``.
public protocol FileManagerClient: Sendable {
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(
        at srcURL: URL,
        to dstURL: URL,
        onlyIfMatches fingerprint: FileOperationFingerprint
    ) throws
    func removeItem(at URL: URL) throws
    func removeItem(at url: URL, onlyIfMatches fingerprint: FileOperationFingerprint) throws
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws
    func volumeIdentifier(for url: URL) throws -> String?
    func copyItemWithProgress(
        at srcURL: URL,
        to dstURL: URL,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws
    func byteCount(of url: URL) -> Int64
    func fingerprint(of url: URL) throws -> FileOperationFingerprint
}

public extension FileManagerClient {
    func copyItemWithProgress(
        at srcURL: URL,
        to dstURL: URL,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        try copyItem(at: srcURL, to: dstURL)
    }

    func byteCount(of url: URL) -> Int64 {
        FileByteCounter.allocatedBytes(at: url)
    }

    func fingerprint(of url: URL) throws -> FileOperationFingerprint {
        try FileOperationFingerprint.capture(at: url)
    }

    func removeItem(at url: URL, onlyIfMatches fingerprint: FileOperationFingerprint) throws {
        guard try self.fingerprint(of: url) == fingerprint else {
            throw FileOperationError.underlying("The item changed before it could be removed.")
        }
        try removeItem(at: url)
    }

    func moveItem(
        at srcURL: URL,
        to dstURL: URL,
        onlyIfMatches fingerprint: FileOperationFingerprint
    ) throws {
        guard try self.fingerprint(of: srcURL) == fingerprint else {
            throw FileOperationError.underlying("The item changed before it could be moved.")
        }
        try moveItem(at: srcURL, to: dstURL)
    }
}

/// Production implementation of ``FileManagerClient``.
public struct LocalFileManagerClient: FileManagerClient, @unchecked Sendable {
    private let manager: FileManager
    private let coordinator: any FileCoordinationClient

    public init(fileManager: FileManager = .default) {
        self.manager = fileManager
        self.coordinator = SystemFileCoordinationClient()
    }

    init(fileManager: FileManager, coordinator: any FileCoordinationClient) {
        self.manager = fileManager
        self.coordinator = coordinator
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        manager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                attributes: [FileAttributeKey: Any]? = nil) throws {
        try coordinator.coordinateWriting(at: url, intent: .createOrModify) { coordinatedURL in
            try manager.createDirectory(
                at: coordinatedURL,
                withIntermediateDirectories: createIntermediates,
                attributes: attributes
            )
        }
    }

    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try coordinator.coordinateReading(
            at: srcURL,
            writingAt: dstURL,
            destinationIntent: .createOrModify
        ) { coordinatedSource, coordinatedDestination in
            try manager.copyItem(at: coordinatedSource, to: coordinatedDestination)
        }
    }

    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try coordinator.coordinateMoving(from: srcURL, to: dstURL) { coordinatedSource, coordinatedDestination in
            try manager.moveItem(at: coordinatedSource, to: coordinatedDestination)
        }
    }

    public func moveItem(
        at srcURL: URL,
        to dstURL: URL,
        onlyIfMatches fingerprint: FileOperationFingerprint
    ) throws {
        try coordinator.coordinateMoving(from: srcURL, to: dstURL) { coordinatedSource, coordinatedDestination in
            guard try FileOperationFingerprint.capture(
                at: coordinatedSource,
                fileManager: manager
            ) == fingerprint else {
                throw FileOperationError.underlying("The item changed before it could be moved.")
            }
            try manager.moveItem(at: coordinatedSource, to: coordinatedDestination)
        }
    }

    public func removeItem(at URL: URL) throws {
        try coordinator.coordinateWriting(at: URL, intent: .delete) { coordinatedURL in
            try manager.removeItem(at: coordinatedURL)
        }
    }

    public func removeItem(at url: URL, onlyIfMatches fingerprint: FileOperationFingerprint) throws {
        try coordinator.coordinateWriting(at: url, intent: .delete) { coordinatedURL in
            guard try FileOperationFingerprint.capture(at: coordinatedURL, fileManager: manager) == fingerprint else {
                throw FileOperationError.underlying("The item changed before it could be removed.")
            }
            try manager.removeItem(at: coordinatedURL)
        }
    }

    public func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>? = nil) throws {
        try coordinator.coordinateWriting(at: url, intent: .move) { coordinatedURL in
            try manager.trashItem(at: coordinatedURL, resultingItemURL: resultingItemURL)
        }
    }

    public func volumeIdentifier(for url: URL) throws -> String? {
        // UUID is stable for the volume and does not require the destination
        // item itself to exist (the caller passes an existing parent).
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIdentifierKey])
        if let uuid = values.volumeUUIDString { return uuid }
        if let identifier = values.volumeIdentifier { return String(describing: identifier) }
        return nil
    }

    public func copyItemWithProgress(
        at srcURL: URL,
        to dstURL: URL,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        try await CopyfileOperation.copy(
            from: srcURL,
            to: dstURL,
            coordinator: coordinator,
            onBytesCopied: onBytesCopied
        )
    }

    public func byteCount(of url: URL) -> Int64 {
        FileByteCounter.allocatedBytes(at: url)
    }

    public func fingerprint(of url: URL) throws -> FileOperationFingerprint {
        try FileOperationFingerprint.capture(at: url, fileManager: manager)
    }
}

/// An actor that serializes mutations and checks cancellation between items.
public actor FileOperationEngine {
    private let fileManager: any FileManagerClient
    private let recoveryJournal: FileOperationRecoveryJournal
    private var isExecuting = false
    private var queuedExecutions: [CheckedContinuation<Void, Never>] = []

    public init(
        fileManager: any FileManagerClient = LocalFileManagerClient(),
        recoveryJournal: FileOperationRecoveryJournal = FileOperationRecoveryJournal()
    ) {
        self.fileManager = fileManager
        self.recoveryJournal = recoveryJournal
    }

    public func execute(_ operation: FileOperation,
                        conflictResolver: (any FileConflictResolving)? = nil,
                        progress: (@Sendable (FileOperationProgress) -> Void)? = nil) async throws -> FileOperationResult {
        try await execute(operation, conflictResolver: conflictResolver, asyncProgress: { value in progress?(value) })
    }

    /// Async progress is useful to clients that need to cancel or update UI
    /// state at an item boundary.
    public func execute(_ operation: FileOperation,
                        conflictResolver: (any FileConflictResolving)? = nil,
                        asyncProgress: (@Sendable (FileOperationProgress) async -> Void)? = nil) async throws -> FileOperationResult {
        let operationID = UUID()
        await acquireExecutionSlot()
        defer { releaseExecutionSlot() }
        do {
            try checkCancellation()
            let result = try await run(
                operation,
                operationID: operationID,
                conflictResolver: conflictResolver,
                progress: asyncProgress
            )
            try checkCancellation()
            return result
        } catch is CancellationError {
            throw FileOperationError.cancelled
        }
    }

    private func run(_ operation: FileOperation, operationID: UUID,
                     conflictResolver: (any FileConflictResolving)?,
                     progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        switch operation {
        case .createFolder(let request):
            return try await runCreateFolder(request, operationID: operationID, conflictResolver: conflictResolver, progress: progress)
        case .rename(let request):
            return try await runRename(request, operationID: operationID, conflictResolver: conflictResolver, progress: progress)
        case .copy(let request):
            return try await runBatch(request, kind: .copy, operationID: operationID, conflictResolver: conflictResolver, progress: progress)
        case .move(let request):
            return try await runBatch(request, kind: .move, operationID: operationID, conflictResolver: conflictResolver, progress: progress)
        case .duplicate(let request):
            return try await runDuplicate(request, operationID: operationID, conflictResolver: conflictResolver, progress: progress)
        case .trash(let request):
            return try await runTrash(request, operationID: operationID, progress: progress)
        case .delete(let request):
            return try await runDelete(request, operationID: operationID, progress: progress)
        }
    }

    private func runCreateFolder(
        _ request: CreateFolderRequest,
        operationID: UUID,
        conflictResolver: (any FileConflictResolving)?,
        progress: (@Sendable (FileOperationProgress) async -> Void)?
    ) async throws -> FileOperationResult {
        try validateName(request.name)
        try validateDirectory(request.parent, missingError: .destinationMissing(request.parent))
        let requested = request.parent.appendingPathComponent(request.name, isDirectory: true)
        let destination = try await resolveConflict(
            at: requested,
            source: requested,
            kind: .createFolder,
            remainingItemCount: 0,
            policy: request.conflictPolicy,
            resolver: conflictResolver
        )
        switch destination {
        case .skip, .stop:
            await report(progress, id: operationID, kind: .createFolder, completed: 1, total: 1, item: requested)
            return FileOperationResult(operationID: operationID, kind: .createFolder,
                                       items: [.init(source: requested, destination: requested, status: .skipped)])
        case let .proceed(url, shouldReplace):
            try checkCancellation()
            do {
                if shouldReplace {
                    try await performStagedFolderCreation(at: url)
                } else {
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: nil)
                }
            } catch { throw map(error, at: url) }
            await report(progress, id: operationID, kind: .createFolder, completed: 1, total: 1, item: requested)
            return FileOperationResult(operationID: operationID, kind: .createFolder,
                                       items: [.init(source: requested, destination: url, status: .completed, replacedExisting: shouldReplace)])
        }
    }

    private func runRename(
        _ request: RenameRequest,
        operationID: UUID,
        conflictResolver: (any FileConflictResolving)?,
        progress: (@Sendable (FileOperationProgress) async -> Void)?
    ) async throws -> FileOperationResult {
        try checkSource(request.source)
        try validateName(request.name)
        let parent = request.source.deletingLastPathComponent()
        try validateDirectory(parent, missingError: .destinationMissing(parent))
        let requested = parent.appendingPathComponent(request.name)
        if requested.standardizedFileURL == request.source.standardizedFileURL {
            throw FileOperationError.sameSourceAndDestination(request.source)
        }
        let destination = try await resolveConflict(
            at: requested,
            source: request.source,
            kind: .rename,
            remainingItemCount: 0,
            policy: request.conflictPolicy,
            resolver: conflictResolver
        )
        switch destination {
        case .skip, .stop:
            await report(progress, id: operationID, kind: .rename, completed: 1, total: 1, item: request.source)
            return FileOperationResult(operationID: operationID, kind: .rename,
                                       items: [.init(source: request.source, destination: requested, status: .skipped)])
        case let .proceed(url, shouldReplace):
            try checkCancellation()
            do {
                if shouldReplace {
                    try await performReplacementMove(from: request.source, to: url)
                } else {
                    try fileManager.moveItem(at: request.source, to: url)
                }
            } catch { throw map(error, at: url) }
            await report(progress, id: operationID, kind: .rename, completed: 1, total: 1, item: request.source)
            return FileOperationResult(operationID: operationID, kind: .rename,
                                       items: [.init(source: request.source, destination: url, status: .completed, replacedExisting: shouldReplace)])
        }
    }

    private func runBatch(
        _ request: FileBatchRequest,
        kind: FileOperationKind,
        operationID: UUID,
        conflictResolver: (any FileConflictResolving)?,
        progress: (@Sendable (FileOperationProgress) async -> Void)?
    ) async throws -> FileOperationResult {
        guard !request.sources.isEmpty else { return FileOperationResult(operationID: operationID, kind: kind, items: []) }
        try validateDirectory(request.destination, missingError: .destinationMissing(request.destination))
        let totalBytes = request.sources.reduce(into: Int64(0)) { $0 += fileManager.byteCount(of: $1) }
        var completedBytes: Int64 = 0
        let throttler = ProgressThrottler()
        var results: [FileOperationItemResult] = []
        for (index, source) in request.sources.enumerated() {
            try checkCancellation()
            try checkSource(source)
            let requested = request.destination.appendingPathComponent(source.lastPathComponent)
            if requested.standardizedFileURL == source.standardizedFileURL {
                throw FileOperationError.sameSourceAndDestination(source)
            }
            try validateNotInside(source: source, destination: requested)
            let itemBytes = fileManager.byteCount(of: source)
            await report(
                progress,
                id: operationID,
                kind: kind,
                completed: index,
                total: request.sources.count,
                item: source,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
            let destination = try await resolveConflict(
                at: requested,
                source: source,
                kind: kind,
                remainingItemCount: request.sources.count - index - 1,
                policy: request.conflictPolicy,
                resolver: conflictResolver
            )
            switch destination {
            case .stop:
                results.append(.init(source: source, destination: requested, status: .skipped))
                results.append(contentsOf: request.sources[(index + 1)...].map {
                    .init(
                        source: $0,
                        destination: request.destination.appendingPathComponent($0.lastPathComponent),
                        status: .skipped
                    )
                })
                await report(
                    progress,
                    id: operationID,
                    kind: kind,
                    completed: index,
                    total: request.sources.count,
                    item: source,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes
                )
                return FileOperationResult(operationID: operationID, kind: kind, items: results)
            case .skip:
                completedBytes += itemBytes
                results.append(.init(source: source, destination: requested, status: .skipped))
            case let .proceed(url, shouldReplace):
                do {
                    if kind == .copy {
                        try await performStagedTransfer(
                            from: source,
                            to: url,
                            replacesDestination: shouldReplace,
                            removesSource: false,
                            operationID: operationID,
                            kind: kind,
                            completedItems: index,
                            totalItems: request.sources.count,
                            baseBytes: completedBytes,
                            totalBytes: totalBytes,
                            throttler: throttler,
                            progress: progress
                        )
                    } else {
                        let sourceVolume = try fileManager.volumeIdentifier(for: source)
                        let destinationVolume = try fileManager.volumeIdentifier(for: request.destination)
                        if let sourceVolume, sourceVolume == destinationVolume, !shouldReplace {
                            try fileManager.moveItem(at: source, to: url)
                        } else if let sourceVolume, sourceVolume == destinationVolume {
                            try await performReplacementMove(from: source, to: url)
                        } else {
                            // Unknown volume identity takes the conservative
                            // path as well: stage the complete copy before any
                            // attempt to remove the source.
                            try await performStagedTransfer(
                                from: source,
                                to: url,
                                replacesDestination: shouldReplace,
                                removesSource: true,
                                operationID: operationID,
                                kind: kind,
                                completedItems: index,
                                totalItems: request.sources.count,
                                baseBytes: completedBytes,
                                totalBytes: totalBytes,
                                throttler: throttler,
                                progress: progress
                            )
                        }
                    }
                } catch {
                    throw map(error, at: url)
                }
                completedBytes += itemBytes
                results.append(.init(source: source, destination: url, status: .completed, replacedExisting: shouldReplace))
            }
            await report(
                progress,
                id: operationID,
                kind: kind,
                completed: index + 1,
                total: request.sources.count,
                item: source,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
            // Yield after every item so cancellation can be observed even
            // when FileManager itself performs a fast operation.
            await Task.yield()
        }
        return FileOperationResult(operationID: operationID, kind: kind, items: results)
    }

    private func runDuplicate(
        _ request: DuplicateRequest,
        operationID: UUID,
        conflictResolver: (any FileConflictResolving)?,
        progress: (@Sendable (FileOperationProgress) async -> Void)?
    ) async throws -> FileOperationResult {
        try checkSource(request.source)
        let requested: URL
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: request.destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            requested = request.destination.appendingPathComponent(request.source.lastPathComponent)
        } else {
            requested = request.destination
        }
        let parent = requested.deletingLastPathComponent()
        try validateDirectory(parent, missingError: .destinationMissing(parent))
        if requested.standardizedFileURL == request.source.standardizedFileURL {
            throw FileOperationError.sameSourceAndDestination(request.source)
        }
        try validateNotInside(source: request.source, destination: requested)
        let totalBytes = fileManager.byteCount(of: request.source)
        let throttler = ProgressThrottler()
        let destination = try await resolveConflict(
            at: requested,
            source: request.source,
            kind: .duplicate,
            remainingItemCount: 0,
            policy: request.conflictPolicy,
            resolver: conflictResolver
        )
        switch destination {
        case .skip, .stop:
            await report(progress, id: operationID, kind: .duplicate, completed: 1, total: 1, item: request.source, totalBytes: totalBytes)
            return FileOperationResult(operationID: operationID, kind: .duplicate,
                                       items: [.init(source: request.source, destination: requested, status: .skipped)])
        case let .proceed(url, shouldReplace):
            try checkCancellation()
            do {
                try await performStagedTransfer(
                    from: request.source,
                    to: url,
                    replacesDestination: shouldReplace,
                    removesSource: false,
                    operationID: operationID,
                    kind: .duplicate,
                    completedItems: 0,
                    totalItems: 1,
                    baseBytes: 0,
                    totalBytes: totalBytes,
                    throttler: throttler,
                    progress: progress
                )
            } catch { throw map(error, at: url) }
            await report(
                progress,
                id: operationID,
                kind: .duplicate,
                completed: 1,
                total: 1,
                item: request.source,
                completedBytes: totalBytes,
                totalBytes: totalBytes
            )
            return FileOperationResult(operationID: operationID, kind: .duplicate,
                                       items: [.init(source: request.source, destination: url, status: .completed, replacedExisting: shouldReplace)])
        }
    }

    private func runTrash(_ request: TrashRequest, operationID: UUID,
                          progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        var results: [FileOperationItemResult] = []
        for (index, source) in request.sources.enumerated() {
            try checkCancellation()
            try checkSource(source)
            var resultingItemURL: NSURL?
            do { try fileManager.trashItem(at: source, resultingItemURL: &resultingItemURL) }
            catch { throw map(error, at: source) }
            results.append(.init(
                source: source,
                destination: resultingItemURL.map { $0 as URL },
                status: .completed
            ))
            await report(progress, id: operationID, kind: .trash, completed: index + 1,
                         total: request.sources.count, item: source)
            await Task.yield()
        }
        return FileOperationResult(operationID: operationID, kind: .trash, items: results)
    }

    private func runDelete(_ request: DeleteRequest, operationID: UUID,
                           progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        guard !request.sources.isEmpty else {
            return FileOperationResult(operationID: operationID, kind: .delete, items: [])
        }
        for source in request.sources {
            try checkCancellation()
            try checkSource(source)
        }

        var results: [FileOperationItemResult] = []
        for (index, source) in request.sources.enumerated() {
            try checkCancellation()
            do {
                try checkSource(source)
                try fileManager.removeItem(at: source)
                results.append(.init(source: source, destination: nil, status: .completed))
            } catch {
                results.append(.init(
                    source: source,
                    destination: nil,
                    status: .failed,
                    failureReason: map(error, at: source).errorDescription
                ))
            }
            await report(progress, id: operationID, kind: .delete, completed: index + 1,
                         total: request.sources.count, item: source)
            await Task.yield()
        }

        if results.contains(where: { $0.status == .completed }) {
            return FileOperationResult(operationID: operationID, kind: .delete, items: results)
        }
        if let firstFailure = results.first(where: { $0.status == .failed }) {
            throw FileOperationError.underlying(
                firstFailure.failureReason ?? FileOperationError.sourceMissing(firstFailure.source).errorDescription ?? "Delete failed."
            )
        }
        throw FileOperationError.sourceMissing(request.sources[0])
    }

    private enum ConflictResolution {
        case proceed(url: URL, shouldReplace: Bool)
        case skip
        case stop
    }

    private func acquireExecutionSlot() async {
        guard isExecuting else {
            isExecuting = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queuedExecutions.append(continuation)
        }
    }

    private func releaseExecutionSlot() {
        if let next = queuedExecutions.first {
            queuedExecutions.removeFirst()
            // Keep the slot occupied while handing it to the next queued call.
            next.resume()
        } else {
            isExecuting = false
        }
    }

    private func resolveConflict(
        at requested: URL,
        source: URL,
        kind: FileOperationKind,
        remainingItemCount: Int,
        policy: FileConflictPolicy,
        resolver: (any FileConflictResolving)?
    ) async throws -> ConflictResolution {
        guard fileManager.fileExists(atPath: requested.path, isDirectory: nil) else {
            return .proceed(url: requested, shouldReplace: false)
        }
        switch policy {
        case .fail:
            throw FileOperationError.destinationExists(requested)
        case .skip:
            return .skip
        case .replace:
            return .proceed(url: requested, shouldReplace: true)
        case .keepBoth:
            return .proceed(url: uniqueKeepBothURL(for: requested), shouldReplace: false)
        case .ask:
            guard let resolver else {
                throw FileOperationError.destinationExists(requested)
            }
            let conflict = FileConflict(
                source: source,
                destination: requested,
                kind: kind,
                remainingItemCount: remainingItemCount
            )
            switch await resolver.resolve(conflict) {
            case .skip:
                return .skip
            case .stop:
                return .stop
            case .replace:
                return .proceed(url: requested, shouldReplace: true)
            case .keepBoth:
                return .proceed(url: uniqueKeepBothURL(for: requested), shouldReplace: false)
            }
        }
    }

    private func uniqueKeepBothURL(for requested: URL) -> URL {
        var candidate = requested
        var index = 1
        while fileManager.fileExists(atPath: candidate.path, isDirectory: nil) {
            candidate = keepBothName(for: requested, number: index)
            index += 1
        }
        return candidate
    }

    private func keepBothName(for url: URL, number: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = number == 1 ? " copy" : " copy \(number)"
        let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Replaces an existing destination with an atomic same-volume move while
    /// recording enough identity information to distinguish a committed move
    /// from one interrupted before the source changed location.
    private func performReplacementMove(from source: URL, to destination: URL) async throws {
        let parent = destination.deletingLastPathComponent()
        let transactionID = UUID()
        let backup = parent.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        let sourceFingerprint = try fileManager.fingerprint(of: source)
        let originalDestinationFingerprint = try fileManager.fingerprint(of: destination)
        let recoveryID = try await recoveryJournal.beginReplacementMove(
            id: transactionID,
            source: source,
            destination: destination,
            backup: backup,
            sourceFingerprint: sourceFingerprint,
            originalDestinationFingerprint: originalDestinationFingerprint
        )
        var moveCommitted = false
        do {
            try fileManager.moveItem(
                at: destination,
                to: backup,
                onlyIfMatches: originalDestinationFingerprint
            )
            try await recoveryJournal.markBackupCreated(recoveryID)
            try checkCancellation()
            guard try fileManager.fingerprint(of: source) == sourceFingerprint else {
                throw FileOperationError.underlying(
                    "The move source changed while the replacement was being prepared."
                )
            }
            try await recoveryJournal.markSourceMovePrepared(recoveryID)
            try fileManager.moveItem(
                at: source,
                to: destination,
                onlyIfMatches: sourceFingerprint
            )
            moveCommitted = true
            try await recoveryJournal.markReplacementCompleted(recoveryID)
            if fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
                try fileManager.removeItem(at: backup, onlyIfMatches: originalDestinationFingerprint)
            }
            try await recoveryJournal.finish(recoveryID)
        } catch {
            if !fileManager.fileExists(atPath: source.path, isDirectory: nil),
               destinationMatches(sourceFingerprint, at: destination) {
                try? await recoveryJournal.markReplacementCompleted(recoveryID)
                if destinationMatches(originalDestinationFingerprint, at: backup) {
                    try? fileManager.removeItem(at: backup, onlyIfMatches: originalDestinationFingerprint)
                }
                if !fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
                    try? await recoveryJournal.finish(recoveryID)
                }
                return
            }
            if moveCommitted {
                throw error
            }

            var rolledBack = true
            if fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
                guard destinationMatches(originalDestinationFingerprint, at: backup),
                      !fileManager.fileExists(atPath: destination.path, isDirectory: nil) else {
                    throw error
                }
                do {
                    try fileManager.moveItem(
                        at: backup,
                        to: destination,
                        onlyIfMatches: originalDestinationFingerprint
                    )
                }
                catch { rolledBack = false }
            }
            if rolledBack {
                try? await recoveryJournal.markRollbackCompleted(recoveryID)
                try? await recoveryJournal.finish(recoveryID)
            }
            throw error
        }
    }

    private func performStagedFolderCreation(at destination: URL) async throws {
        let parent = destination.deletingLastPathComponent()
        let transactionID = UUID()
        let staging = parent.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        let backup = parent.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        let originalDestinationFingerprint = try fileManager.fingerprint(of: destination)
        let recoveryID = try await recoveryJournal.beginStagedTransfer(
            id: transactionID,
            source: staging,
            destination: destination,
            staging: staging,
            backup: backup,
            originalDestinationFingerprint: originalDestinationFingerprint,
            removesSource: false
        )
        var stagingFingerprint: FileOperationFingerprint?
        var destinationWasCommitted = false
        var semanticOperationCompleted = false
        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: nil
            )
            let createdFingerprint = try fileManager.fingerprint(of: staging)
            stagingFingerprint = createdFingerprint
            try await recoveryJournal.markStagedCopyCompleted(
                recoveryID,
                sourceFingerprint: createdFingerprint,
                stagingFingerprint: createdFingerprint
            )
            try checkCancellation()
            try fileManager.moveItem(
                at: destination,
                to: backup,
                onlyIfMatches: originalDestinationFingerprint
            )
            try await recoveryJournal.markBackupCreated(recoveryID)
            try fileManager.moveItem(
                at: staging,
                to: destination,
                onlyIfMatches: createdFingerprint
            )
            destinationWasCommitted = true
            try await recoveryJournal.markDestinationCommitted(recoveryID)
            semanticOperationCompleted = true
            try fileManager.removeItem(at: backup, onlyIfMatches: originalDestinationFingerprint)
            try await recoveryJournal.finish(recoveryID)
        } catch {
            if semanticOperationCompleted { return }
            let rolledBack = rollbackStagedTransfer(
                destination: destination,
                staging: staging,
                backup: backup,
                originalDestinationFingerprint: originalDestinationFingerprint,
                stagingFingerprint: stagingFingerprint,
                destinationWasCommitted: destinationWasCommitted
            )
            if rolledBack { try? await recoveryJournal.finish(recoveryID) }
            throw error
        }
    }

    /// Copies into a hidden sibling first, then commits that complete item with
    /// a same-volume rename. The recovery record is written before any file
    /// mutation so a process interruption can never expose a partial item at
    /// the user's requested destination.
    private func performStagedTransfer(
        from source: URL,
        to destination: URL,
        replacesDestination: Bool,
        removesSource: Bool,
        operationID: UUID,
        kind: FileOperationKind,
        completedItems: Int,
        totalItems: Int,
        baseBytes: Int64,
        totalBytes: Int64,
        throttler: ProgressThrottler,
        progress: (@Sendable (FileOperationProgress) async -> Void)?
    ) async throws {
        let parent = destination.deletingLastPathComponent()
        let transactionID = UUID()
        let staging = parent.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        let backup = replacesDestination
            ? parent.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
            : nil
        let sourceFingerprintBeforeCopy = try fileManager.fingerprint(of: source)
        let originalDestinationFingerprint = try backup.map { _ in
            try fileManager.fingerprint(of: destination)
        }
        let recoveryID = try await recoveryJournal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: backup,
            originalDestinationFingerprint: originalDestinationFingerprint,
            removesSource: removesSource
        )

        var stagingFingerprint: FileOperationFingerprint?
        var destinationWasCommitted = false
        var semanticOperationCompleted = false
        do {
            try await copyReportingProgress(
                from: source,
                to: staging,
                operationID: operationID,
                kind: kind,
                completedItems: completedItems,
                totalItems: totalItems,
                baseBytes: baseBytes,
                totalBytes: totalBytes,
                throttler: throttler,
                progress: progress
            )
            let capturedSource = try fileManager.fingerprint(of: source)
            guard capturedSource == sourceFingerprintBeforeCopy else {
                throw FileOperationError.underlying(
                    "The source changed while it was being copied; the incomplete transfer was discarded."
                )
            }
            let capturedStaging = try fileManager.fingerprint(of: staging)
            stagingFingerprint = capturedStaging
            try await recoveryJournal.markStagedCopyCompleted(
                recoveryID,
                sourceFingerprint: capturedSource,
                stagingFingerprint: capturedStaging
            )
            try checkCancellation()

            if let backup, let expectedDestination = originalDestinationFingerprint {
                guard try fileManager.fingerprint(of: destination) == expectedDestination else {
                    throw FileOperationError.underlying(
                        "The destination changed while the copy was being prepared."
                    )
                }
                try fileManager.moveItem(
                    at: destination,
                    to: backup,
                    onlyIfMatches: expectedDestination
                )
                try await recoveryJournal.markBackupCreated(recoveryID)
            }

            try fileManager.moveItem(
                at: staging,
                to: destination,
                onlyIfMatches: capturedStaging
            )
            destinationWasCommitted = true
            try await recoveryJournal.markDestinationCommitted(recoveryID)

            if removesSource {
                try checkCancellation()
                guard try fileManager.fingerprint(of: source) == capturedSource else {
                    throw FileOperationError.underlying(
                        "The move source changed while it was being copied; the source was preserved."
                    )
                }
                try await recoveryJournal.markSourceDeletionPrepared(recoveryID)
                try fileManager.removeItem(at: source, onlyIfMatches: capturedSource)
                semanticOperationCompleted = true
                try await recoveryJournal.markSourceRemoved(recoveryID)
            } else {
                semanticOperationCompleted = true
            }

            if let backup,
               let originalDestinationFingerprint,
               fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
                try fileManager.removeItem(
                    at: backup,
                    onlyIfMatches: originalDestinationFingerprint
                )
            }
            try await recoveryJournal.finish(recoveryID)
        } catch {
            // If the source deletion succeeded but its journal update failed,
            // the requested move is already complete. Preserve the destination
            // and leave any remaining journal work for startup recovery.
            if removesSource,
               !fileManager.fileExists(atPath: source.path, isDirectory: nil),
               destinationMatches(stagingFingerprint, at: destination) {
                try? await recoveryJournal.markSourceRemoved(recoveryID)
                if let backup, fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
                    if let originalDestinationFingerprint {
                        try? fileManager.removeItem(
                            at: backup,
                            onlyIfMatches: originalDestinationFingerprint
                        )
                    }
                }
                if backup.map({ fileManager.fileExists(atPath: $0.path, isDirectory: nil) }) != true {
                    try? await recoveryJournal.finish(recoveryID)
                }
                return
            }
            if semanticOperationCompleted {
                return
            }

            let rolledBack = rollbackStagedTransfer(
                destination: destination,
                staging: staging,
                backup: backup,
                originalDestinationFingerprint: originalDestinationFingerprint,
                stagingFingerprint: stagingFingerprint,
                destinationWasCommitted: destinationWasCommitted
            )
            if rolledBack {
                try? await recoveryJournal.finish(recoveryID)
            }
            throw error
        }
    }

    private func rollbackStagedTransfer(
        destination: URL,
        staging: URL,
        backup: URL?,
        originalDestinationFingerprint: FileOperationFingerprint?,
        stagingFingerprint: FileOperationFingerprint?,
        destinationWasCommitted: Bool
    ) -> Bool {
        var succeeded = true
        let committedItemExists = destinationWasCommitted
            || (!fileManager.fileExists(atPath: staging.path, isDirectory: nil)
                && destinationMatches(stagingFingerprint, at: destination))
        if committedItemExists,
           fileManager.fileExists(atPath: destination.path, isDirectory: nil) {
            guard let stagingFingerprint,
                  destinationMatches(stagingFingerprint, at: destination) else { return false }
            do { try fileManager.removeItem(at: destination, onlyIfMatches: stagingFingerprint) }
            catch { succeeded = false }
        }
        if fileManager.fileExists(atPath: staging.path, isDirectory: nil) {
            do { try fileManager.removeItem(at: staging) }
            catch { succeeded = false }
        }
        if let backup, fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
            guard destinationMatches(originalDestinationFingerprint, at: backup),
                  !fileManager.fileExists(atPath: destination.path, isDirectory: nil) else {
                return false
            }
            guard let originalDestinationFingerprint else { return false }
            do {
                try fileManager.moveItem(
                    at: backup,
                    to: destination,
                    onlyIfMatches: originalDestinationFingerprint
                )
            }
            catch { succeeded = false }
        } else if backup != nil,
                  !destinationMatches(originalDestinationFingerprint, at: destination) {
            succeeded = false
        }
        return succeeded
    }

    private func destinationMatches(
        _ fingerprint: FileOperationFingerprint?,
        at url: URL
    ) -> Bool {
        guard let fingerprint,
              fileManager.fileExists(atPath: url.path, isDirectory: nil) else { return false }
        return (try? fileManager.fingerprint(of: url)) == fingerprint
    }

    private func copyReportingProgress(
        from source: URL,
        to destination: URL,
        operationID: UUID,
        kind: FileOperationKind,
        completedItems: Int,
        totalItems: Int,
        baseBytes: Int64,
        totalBytes: Int64,
        throttler: ProgressThrottler,
        progress: (@Sendable (FileOperationProgress) async -> Void)?
    ) async throws {
        do {
            try await fileManager.copyItemWithProgress(at: source, to: destination) { copied in
                guard throttler.shouldReport() else { return }
                await self.report(
                    progress,
                    id: operationID,
                    kind: kind,
                    completed: completedItems,
                    total: totalItems,
                    item: source,
                    completedBytes: baseBytes + copied,
                    totalBytes: totalBytes
                )
            }
        } catch {
            if fileManager.fileExists(atPath: destination.path, isDirectory: nil) {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    private func checkSource(_ source: URL) throws {
        guard !source.path.isEmpty else { throw FileOperationError.invalidSource(source) }
        guard fileManager.fileExists(atPath: source.path, isDirectory: nil) else {
            throw FileOperationError.sourceMissing(source)
        }
    }

    private func validateDirectory(_ url: URL, missingError: FileOperationError) throws {
        var directory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &directory) else { throw missingError }
        guard directory.boolValue else { throw FileOperationError.destinationNotDirectory(url) }
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw FileOperationError.invalidName(name)
        }
    }

    private func validateNotInside(source: URL, destination: URL) throws {
        // `standardizedFileURL` is lexical and leaves symlinked parents intact.
        // Resolve existing components so a destination such as
        // `/source/link-to-child` cannot evade the containment guard.
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        // The final destination normally does not exist yet, and Foundation may
        // leave intermediate symlinks unresolved in that case. Its parent was
        // already validated as an existing directory, so resolve that directory
        // first and then append the proposed item name.
        let canonicalDestinationParent = destination.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalDestination = canonicalDestinationParent
            .appendingPathComponent(destination.lastPathComponent)
            .standardizedFileURL
        if isDescendantPath(canonicalDestination.path, of: canonicalSource.path) ||
            // macOS commonly uses case-insensitive volumes. A conservative
            // case-folded check prevents a casing-only spelling from escaping
            // the guard; on case-sensitive volumes a differently-cased path
            // would have failed destination validation before this point.
            isDescendantPath(canonicalDestination.path.lowercased(), of: canonicalSource.path.lowercased()) {
            var directory = ObjCBool(false)
            if fileManager.fileExists(atPath: source.path, isDirectory: &directory), directory.boolValue {
                throw FileOperationError.invalidDestination(canonicalDestination)
            }
        }
    }

    private func isDescendantPath(_ candidate: String, of ancestor: String) -> Bool {
        let normalizedAncestor = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return candidate.hasPrefix(normalizedAncestor)
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw FileOperationError.cancelled }
    }

    private func report(
        _ progress: (@Sendable (FileOperationProgress) async -> Void)?,
        id: UUID,
        kind: FileOperationKind,
        completed: Int,
        total: Int,
        item: URL,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil
    ) async {
        guard let progress else { return }
        await progress(FileOperationProgress(
            operationID: id,
            kind: kind,
            completedItems: completed,
            totalItems: total,
            currentItem: item,
            completedBytes: completedBytes,
            totalBytes: totalBytes
        ))
    }

    private func map(_ error: Error, at url: URL) -> FileOperationError {
        if let operationError = error as? FileOperationError { return operationError }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError {
            return .sourceMissing(url)
        }
        if nsError.domain == NSCocoaErrorDomain &&
            (nsError.code == NSFileWriteNoPermissionError || nsError.code == NSFileReadNoPermissionError) {
            return .permissionDenied(url)
        }
        return .underlying(nsError.localizedDescription)
    }
}
