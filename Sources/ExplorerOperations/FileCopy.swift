import Darwin
import Foundation

enum FileByteCounter {
    static func allocatedBytes(at url: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let item = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if item.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if item.isRegularFile == true {
                total += Int64(item.totalFileAllocatedSize ?? item.fileSize ?? 0)
            }
        }
        return total
    }
}

final class ProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = ContinuousClock.now.advanced(by: .seconds(-1))

    func shouldReport() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        guard now - lastReport >= Duration.milliseconds(80) else { return false }
        lastReport = now
        return true
    }
}

enum CopyfileOperation {
    static func copy(
        from source: URL,
        to destination: URL,
        coordinator: any FileCoordinationClient,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        let stream = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
        let copyTask = Task.detached(priority: .userInitiated) {
            do {
                try coordinator.coordinateReading(
                    at: source,
                    writingAt: destination,
                    destinationIntent: .createOrModify
                ) { coordinatedSource, coordinatedDestination in
                    try performCopyfile(from: coordinatedSource, to: coordinatedDestination) { copied in
                        stream.continuation.yield(copied)
                    }
                }
                stream.continuation.finish()
            } catch {
                stream.continuation.finish()
                throw error
            }
        }
        try await withTaskCancellationHandler {
            var iterator = stream.stream.makeAsyncIterator()
            while let copied = await iterator.next() {
                await onBytesCopied(copied)
            }
            do {
                try await copyTask.value
            } catch is CancellationError {
                throw FileOperationError.cancelled
            }
        } onCancel: {
            copyTask.cancel()
        }
    }

    private static func performCopyfile(
        from source: URL,
        to destination: URL,
        onCopied: @escaping @Sendable (Int64) -> Void
    ) throws {
        guard let state = copyfile_state_alloc() else {
            throw FileOperationError.underlying("Unable to allocate copy state.")
        }
        defer { copyfile_state_free(state) }

        let context = CopyfileContext(onCopied: onCopied)
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }

        let callback: copyfile_callback_t = { what, stage, state, src, dst, ctx in
            copyfileStatusCallback(what, stage, state, src, dst, ctx)
        }
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())

        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL
        )
        let status = source.path.withCString { srcPath in
            destination.path.withCString { dstPath in
                copyfile(srcPath, dstPath, state, flags)
            }
        }
        if context.cancelled || Task.isCancelled {
            throw FileOperationError.cancelled
        }
        guard status == 0 else {
            let code = context.posixError != 0 ? context.posixError : errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }
}

private final class CopyfileContext: @unchecked Sendable {
    let onCopied: @Sendable (Int64) -> Void
    var finishedBytes: Int64 = 0
    var cancelled = false
    var posixError: Int32 = 0

    init(onCopied: @escaping @Sendable (Int64) -> Void) {
        self.onCopied = onCopied
    }
}

private func copyfileStatusCallback(
    _ what: Int32,
    _ stage: Int32,
    _ state: copyfile_state_t?,
    _ src: UnsafePointer<CChar>?,
    _ dst: UnsafePointer<CChar>?,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyfileContext>.fromOpaque(ctx).takeUnretainedValue()
    if Task.isCancelled {
        context.cancelled = true
        return COPYFILE_QUIT
    }
    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS, let state {
        var copied: off_t = 0
        _ = withUnsafeMutablePointer(to: &copied) { pointer in
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), pointer)
        }
        context.onCopied(context.finishedBytes + Int64(copied))
    }
    if what == COPYFILE_RECURSE_FILE && stage == COPYFILE_FINISH, let src {
        context.finishedBytes += FileByteCounter.allocatedBytes(at: URL(fileURLWithPath: String(cString: src)))
        context.onCopied(context.finishedBytes)
    }
    if stage == COPYFILE_ERR {
        context.posixError = errno
        return COPYFILE_QUIT
    }
    return COPYFILE_CONTINUE
}
