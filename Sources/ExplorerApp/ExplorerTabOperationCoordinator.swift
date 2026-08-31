import AppKit
import ExplorerOperations

/// Tracks the operations submitted by one tab and translates queue activity
/// into tab-level status and completion events.
@MainActor
final class ExplorerTabOperationCoordinator {
    var onStatus: ((String) -> Void)?
    var onCompleted: ((FileOperation, FileOperationResult) -> Void)?
    var onRefresh: (() -> Void)?

    private let queue: FileOperationQueue
    private var pendingIDs = Set<UUID>()
    private var pendingSubmissionCount = 0

    init(queue: FileOperationQueue) {
        self.queue = queue
    }

    var hasPendingOperations: Bool { pendingSubmissionCount > 0 }

    func handle(_ event: FileOperationQueueEvent) {
        switch event {
        case let .progress(progress) where pendingIDs.contains(progress.id):
            let detail = progress.progress.currentItem?.lastPathComponent ?? "item"
            onStatus?(
                "\(progress.progress.kind.progressiveName) "
                    + "\(progress.progress.completedItems) of \(progress.progress.totalItems) — \(detail)"
            )
        case let .stateChanged(snapshot) where pendingIDs.contains(snapshot.id):
            switch snapshot.state {
            case .queued:
                onStatus?("\(snapshot.operation.kind.displayName) queued.")
            case .running:
                onStatus?("\(snapshot.operation.kind.progressiveName)…")
            case .completed, .failed, .cancelled:
                // `submit` awaits the result because the first stream event can
                // arrive before the tab has registered the operation ID.
                break
            }
        default:
            break
        }
    }

    func submit(
        _ operation: FileOperation,
        window: NSWindow?,
        completion: ((FileOperationResult) -> Void)? = nil,
        finished: (() -> Void)? = nil
    ) {
        let resolver: (any FileConflictResolving)? = operation.conflictPolicy == .ask
            ? FileConflictCoordinator(window: window)
            : nil
        let queue = queue
        pendingSubmissionCount += 1
        Task { [weak self] in
            defer {
                self?.pendingSubmissionCount -= 1
                finished?()
            }
            let id = await queue.submit(operation, conflictResolver: resolver)
            guard let self else { return }
            self.pendingIDs.insert(id)
            self.onStatus?("\(operation.kind.displayName) queued.")
            do {
                let result = try await queue.result(for: id)
                guard self.pendingIDs.remove(id) != nil else { return }
                self.onCompleted?(operation, result)
                completion?(result)
                self.onStatus?(Self.completionStatus(for: operation.kind, result: result))
                self.onRefresh?()
            } catch {
                guard self.pendingIDs.remove(id) != nil else { return }
                self.onStatus?(error.localizedDescription)
            }
        }
    }

    private static func completionStatus(
        for kind: FileOperationKind,
        result: FileOperationResult
    ) -> String {
        if result.didCompletePartially {
            return "\(kind.completionName) \(result.completedItems) of \(result.items.count) items."
        }
        if result.failedItems > 0 {
            return "\(kind.displayName) failed."
        }
        if result.skippedItems > 0 {
            return "\(kind.completionName) "
                + "(\(result.completedItems) completed, \(result.skippedItems) skipped)."
        }
        return "\(kind.completionName)."
    }
}
