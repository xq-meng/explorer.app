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
    func removeItem(at URL: URL) throws
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws
    func volumeIdentifier(for url: URL) throws -> String?
    func copyItemWithProgress(
        at srcURL: URL,
        to dstURL: URL,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws
    func byteCount(of url: URL) -> Int64
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
}

/// Production implementation of ``FileManagerClient``.
public struct LocalFileManagerClient: FileManagerClient, @unchecked Sendable {
    private let manager: FileManager

    public init(fileManager: FileManager = .default) {
        self.manager = fileManager
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        manager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    public func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                attributes: [FileAttributeKey: Any]? = nil) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: createIntermediates,
                                    attributes: attributes)
    }

    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try manager.copyItem(at: srcURL, to: dstURL)
    }

    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try manager.moveItem(at: srcURL, to: dstURL)
    }

    public func removeItem(at URL: URL) throws { try manager.removeItem(at: URL) }

    public func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>? = nil) throws {
        try manager.trashItem(at: url, resultingItemURL: resultingItemURL)
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
        try await CopyfileOperation.copy(from: srcURL, to: dstURL, onBytesCopied: onBytesCopied)
    }

    public func byteCount(of url: URL) -> Int64 {
        FileByteCounter.allocatedBytes(at: url)
    }
}

/// An actor that serializes mutations and checks cancellation between items.
public actor FileOperationEngine {
    private let fileManager: any FileManagerClient
    private var isExecuting = false
    private var queuedExecutions: [CheckedContinuation<Void, Never>] = []

    public init(fileManager: any FileManagerClient = LocalFileManagerClient()) {
        self.fileManager = fileManager
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
                try await withReplacementBackup(at: requested, enabled: shouldReplace) {
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
                try await withReplacementBackup(at: requested, enabled: shouldReplace) {
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
                    try await withReplacementBackup(at: requested, enabled: shouldReplace) {
                        if kind == .copy {
                            try await copyReportingProgress(
                                from: source,
                                to: url,
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
                            if sourceVolume != nil && destinationVolume != nil && sourceVolume != destinationVolume {
                                // A cross-volume move is copy-then-remove.  Never
                                // remove the source before copy reports success.
                                try await copyReportingProgress(
                                    from: source,
                                    to: url,
                                    operationID: operationID,
                                    kind: kind,
                                    completedItems: index,
                                    totalItems: request.sources.count,
                                    baseBytes: completedBytes,
                                    totalBytes: totalBytes,
                                    throttler: throttler,
                                    progress: progress
                                )
                                try checkCancellation()
                                try fileManager.removeItem(at: source)
                            } else {
                                try fileManager.moveItem(at: source, to: url)
                            }
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
                try await withReplacementBackup(at: requested, enabled: shouldReplace) {
                    try await copyReportingProgress(
                        from: request.source,
                        to: url,
                        operationID: operationID,
                        kind: .duplicate,
                        completedItems: 0,
                        totalItems: 1,
                        baseBytes: 0,
                        totalBytes: totalBytes,
                        throttler: throttler,
                        progress: progress
                    )
                }
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

    /// Replaces a destination without making the old item unrecoverable if the
    /// new operation fails. The backup lives beside the destination, therefore
    /// this also works for a cross-volume source move.
    private func withReplacementBackup(at destination: URL, enabled: Bool,
                                       operation: () async throws -> Void) async throws {
        guard enabled else {
            try await operation()
            return
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".explorer-replace-\(UUID().uuidString)")
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try await operation()
        } catch {
            // Best effort cleanup of a partial result, followed by restoration
            // of the old destination. Preserve the original operation error.
            if fileManager.fileExists(atPath: destination.path, isDirectory: nil) {
                try? fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: backup.path, isDirectory: nil) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
        // If cleanup fails, retain the backup and report the failure.  The
        // successful replacement and the old item are still both present,
        // which is safer than deleting the replacement to restore an item
        // whose operation already completed.
        try fileManager.removeItem(at: backup)
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
