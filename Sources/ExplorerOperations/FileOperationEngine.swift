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
                        progress: (@Sendable (FileOperationProgress) -> Void)? = nil) async throws -> FileOperationResult {
        try await execute(operation, asyncProgress: { value in progress?(value) })
    }

    /// Async progress is useful to clients that need to cancel or update UI
    /// state at an item boundary.
    public func execute(_ operation: FileOperation,
                        asyncProgress: (@Sendable (FileOperationProgress) async -> Void)? = nil) async throws -> FileOperationResult {
        let operationID = UUID()
        await acquireExecutionSlot()
        do {
            try checkCancellation()
            let result = try await run(operation, operationID: operationID, progress: asyncProgress)
            try checkCancellation()
            releaseExecutionSlot()
            return result
        } catch is CancellationError {
            releaseExecutionSlot()
            throw FileOperationError.cancelled
        } catch {
            releaseExecutionSlot()
            throw error
        }
    }

    private func run(_ operation: FileOperation, operationID: UUID,
                     progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        switch operation {
        case .createFolder(let request):
            return try await runCreateFolder(request, operationID: operationID, progress: progress)
        case .rename(let request):
            return try await runRename(request, operationID: operationID, progress: progress)
        case .copy(let request):
            return try await runBatch(request, kind: .copy, operationID: operationID, progress: progress)
        case .move(let request):
            return try await runBatch(request, kind: .move, operationID: operationID, progress: progress)
        case .duplicate(let request):
            return try await runDuplicate(request, operationID: operationID, progress: progress)
        case .trash(let request):
            return try await runTrash(request, operationID: operationID, progress: progress)
        }
    }

    private func runCreateFolder(_ request: CreateFolderRequest, operationID: UUID,
                                 progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        try validateName(request.name)
        try validateDirectory(request.parent, missingError: .destinationMissing(request.parent))
        let requested = request.parent.appendingPathComponent(request.name, isDirectory: true)
        let destination = try resolveConflict(at: requested, policy: request.conflictPolicy)
        if destination.wasSkipped {
            await report(progress, id: operationID, kind: .createFolder, completed: 1, total: 1, item: requested)
            return FileOperationResult(operationID: operationID, kind: .createFolder,
                                       items: [.init(source: requested, destination: requested, status: .skipped)])
        }
        try checkCancellation()
        do {
            try withReplacementBackup(at: requested, enabled: destination.shouldReplace) {
                try fileManager.createDirectory(at: destination.url, withIntermediateDirectories: false, attributes: nil)
            }
        } catch { throw map(error, at: destination.url) }
        await report(progress, id: operationID, kind: .createFolder, completed: 1, total: 1, item: requested)
        return FileOperationResult(operationID: operationID, kind: .createFolder,
                                   items: [.init(source: requested, destination: destination.url, status: .completed)])
    }

    private func runRename(_ request: RenameRequest, operationID: UUID,
                           progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        try checkSource(request.source)
        try validateName(request.name)
        let parent = request.source.deletingLastPathComponent()
        try validateDirectory(parent, missingError: .destinationMissing(parent))
        let requested = parent.appendingPathComponent(request.name)
        if requested.standardizedFileURL == request.source.standardizedFileURL {
            throw FileOperationError.sameSourceAndDestination(request.source)
        }
        let destination = try resolveConflict(at: requested, policy: request.conflictPolicy)
        if destination.wasSkipped {
            await report(progress, id: operationID, kind: .rename, completed: 1, total: 1, item: request.source)
            return FileOperationResult(operationID: operationID, kind: .rename,
                                       items: [.init(source: request.source, destination: requested, status: .skipped)])
        }
        try checkCancellation()
        do {
            try withReplacementBackup(at: requested, enabled: destination.shouldReplace) {
                try fileManager.moveItem(at: request.source, to: destination.url)
            }
        }
        catch { throw map(error, at: destination.url) }
        await report(progress, id: operationID, kind: .rename, completed: 1, total: 1, item: request.source)
        return FileOperationResult(operationID: operationID, kind: .rename,
                                   items: [.init(source: request.source, destination: destination.url, status: .completed)])
    }

    private func runBatch(_ request: FileBatchRequest, kind: FileOperationKind, operationID: UUID,
                          progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
        guard !request.sources.isEmpty else { return FileOperationResult(operationID: operationID, kind: kind, items: []) }
        try validateDirectory(request.destination, missingError: .destinationMissing(request.destination))
        var results: [FileOperationItemResult] = []
        for (index, source) in request.sources.enumerated() {
            try checkCancellation()
            try checkSource(source)
            let requested = request.destination.appendingPathComponent(source.lastPathComponent)
            if requested.standardizedFileURL == source.standardizedFileURL {
                throw FileOperationError.sameSourceAndDestination(source)
            }
            if kind == .copy || kind == .move {
                try validateNotInside(source: source, destination: requested)
            }
            let destination = try resolveConflict(at: requested, policy: request.conflictPolicy)
            if destination.wasSkipped {
                results.append(.init(source: source, destination: requested, status: .skipped))
            } else {
                do {
                    try withReplacementBackup(at: requested, enabled: destination.shouldReplace) {
                        if kind == .copy {
                            try fileManager.copyItem(at: source, to: destination.url)
                        } else {
                            let sourceVolume = try fileManager.volumeIdentifier(for: source)
                            let destinationVolume = try fileManager.volumeIdentifier(for: request.destination)
                            if sourceVolume != nil && destinationVolume != nil && sourceVolume != destinationVolume {
                                // A cross-volume move is copy-then-remove.  Never
                                // remove the source before copy reports success.
                                try fileManager.copyItem(at: source, to: destination.url)
                                try checkCancellation()
                                try fileManager.removeItem(at: source)
                            } else {
                                try fileManager.moveItem(at: source, to: destination.url)
                            }
                        }
                    }
                } catch { throw map(error, at: destination.url) }
                results.append(.init(source: source, destination: destination.url, status: .completed))
            }
            await report(progress, id: operationID, kind: kind, completed: index + 1,
                         total: request.sources.count, item: source)
            // Yield after every item so cancellation can be observed even
            // when FileManager itself performs a fast operation.
            await Task.yield()
        }
        return FileOperationResult(operationID: operationID, kind: kind, items: results)
    }

    private func runDuplicate(_ request: DuplicateRequest, operationID: UUID,
                              progress: (@Sendable (FileOperationProgress) async -> Void)?) async throws -> FileOperationResult {
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
        let destination = try resolveConflict(at: requested, policy: request.conflictPolicy)
        if destination.wasSkipped {
            await report(progress, id: operationID, kind: .duplicate, completed: 1, total: 1, item: request.source)
            return FileOperationResult(operationID: operationID, kind: .duplicate,
                                       items: [.init(source: request.source, destination: requested, status: .skipped)])
        }
        try checkCancellation()
        do {
            try withReplacementBackup(at: requested, enabled: destination.shouldReplace) {
                try fileManager.copyItem(at: request.source, to: destination.url)
            }
        }
        catch { throw map(error, at: destination.url) }
        await report(progress, id: operationID, kind: .duplicate, completed: 1, total: 1, item: request.source)
        return FileOperationResult(operationID: operationID, kind: .duplicate,
                                   items: [.init(source: request.source, destination: destination.url, status: .completed)])
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

    private struct ConflictResolution {
        let url: URL
        let wasSkipped: Bool
        let shouldReplace: Bool
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

    private func resolveConflict(at requested: URL, policy: FileConflictPolicy) throws -> ConflictResolution {
        guard fileManager.fileExists(atPath: requested.path, isDirectory: nil) else {
            return ConflictResolution(url: requested, wasSkipped: false, shouldReplace: false)
        }
        switch policy {
        case .fail: throw FileOperationError.destinationExists(requested)
        case .skip: return ConflictResolution(url: requested, wasSkipped: true, shouldReplace: false)
        case .replace: return ConflictResolution(url: requested, wasSkipped: false, shouldReplace: true)
        case .keepBoth:
            var candidate = requested
            var index = 1
            while fileManager.fileExists(atPath: candidate.path, isDirectory: nil) {
                candidate = keepBothName(for: requested, number: index)
                index += 1
            }
            return ConflictResolution(url: candidate, wasSkipped: false, shouldReplace: false)
        }
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
                                       operation: () throws -> Void) throws {
        guard enabled else {
            try operation()
            return
        }
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".explorer-replace-\(UUID().uuidString)")
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try operation()
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

    private func report(_ progress: (@Sendable (FileOperationProgress) async -> Void)?,
                        id: UUID, kind: FileOperationKind, completed: Int, total: Int, item: URL) async {
        guard let progress else { return }
        await progress(FileOperationProgress(operationID: id, kind: kind,
                                             completedItems: completed, totalItems: total, currentItem: item))
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
