import Foundation
import XCTest
@testable import ExplorerOperations

final class FileOperationEngineTests: XCTestCase {
    private var root: URL!
    private var engine: FileOperationEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerOperationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        engine = FileOperationEngine()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCreateFolderAndRename() async throws {
        let folder = try await engine.execute(.createFolder(at: root, name: "Inbox"))
        XCTAssertEqual(folder.kind, .createFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox").path))

        let renamed = try await engine.execute(.rename(source: root.appendingPathComponent("Inbox"), name: "Archive"))
        XCTAssertEqual(renamed.completedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Archive").path))
    }

    func testCopyMoveAndDuplicate() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let moveDestination = root.appendingPathComponent("MoveDestination", isDirectory: true)
        try Data("hello".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: moveDestination, withIntermediateDirectories: false)

        _ = try await engine.execute(.copy(sources: [source], to: destination))
        let copied = destination.appendingPathComponent("source.txt")
        XCTAssertEqual(try String(contentsOf: copied), "hello")

        let duplicate = try await engine.execute(.duplicate(source: source,
                                                              to: destination,
                                                              conflictPolicy: .keepBoth))
        XCTAssertEqual(duplicate.completedItems, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source copy.txt").path))

        _ = try await engine.execute(.move(sources: [source], to: moveDestination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moveDestination.appendingPathComponent("source.txt").path))
    }

    func testConflictPoliciesNeverOverwriteByDefault() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let existing = destination.appendingPathComponent("source.txt")
        try Data("new".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: existing)

        do {
            _ = try await engine.execute(.copy(sources: [source], to: destination))
            XCTFail("Expected a conflict")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .destinationExists(existing))
        }
        XCTAssertEqual(try String(contentsOf: existing), "old")

        let skipped = try await engine.execute(.copy(sources: [source], to: destination, conflictPolicy: .skip))
        XCTAssertEqual(skipped.skippedItems, 1)
        _ = try await engine.execute(.copy(sources: [source], to: destination, conflictPolicy: .replace))
        XCTAssertEqual(try String(contentsOf: existing), "new")
    }

    func testReplaceRestoresExistingItemWhenCopyFails() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let existing = destination.appendingPathComponent("source.txt")
        try Data("new".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: existing)

        let failingClient = FailingCopyFileManager()
        let safeEngine = FileOperationEngine(fileManager: failingClient)
        do {
            _ = try await safeEngine.execute(.copy(sources: [source], to: destination, conflictPolicy: .replace))
            XCTFail("Expected injected copy failure")
        } catch {
            XCTAssertEqual(try String(contentsOf: existing), "old")
        }
    }

    func testCancellationBeforeOperationDoesNotMutate() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try Data("hello".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        let localEngine = try XCTUnwrap(engine)
        let task = Task {
            try await localEngine.execute(.copy(sources: [source], to: destination))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source.txt").path))
    }

    func testTrashOnlyUsesTemporaryTestItem() async throws {
        let source = root.appendingPathComponent("trash-me.txt")
        try Data("temporary".utf8).write(to: source)
        let spy = TrashRecordingFileManager()
        let safeEngine = FileOperationEngine(fileManager: spy)
        let result = try await safeEngine.execute(.trash(sources: [source]))
        XCTAssertEqual(spy.trashed, [source])
        XCTAssertEqual(result.items.first?.destination, spy.resultingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testQueueContinuesAfterFailureAndKeepsStableIDs() async throws {
        let queue = FileOperationQueue()
        let missing = root.appendingPathComponent("missing")
        let failedID = await queue.submit(.copy(sources: [missing], to: root))
        let createdID = await queue.submit(.createFolder(at: root, name: "AfterFailure"))

        do {
            _ = try await queue.result(for: failedID)
            XCTFail("Expected first operation to fail")
        } catch {
            let failedSnapshot = await queue.snapshot(for: failedID)
            XCTAssertEqual(failedSnapshot?.state, .failed)
        }
        let result = try await queue.result(for: createdID)
        XCTAssertEqual(result.operationID, createdID)
        let completedSnapshot = await queue.snapshot(for: createdID)
        XCTAssertEqual(completedSnapshot?.state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("AfterFailure").path))
        let allSnapshots = await queue.snapshots()
        XCTAssertEqual(allSnapshots.map(\.id), [failedID, createdID])
    }

    func testQueueCanCancelQueuedOperation() async throws {
        let queue = FileOperationQueue()
        // Cancellation before the worker starts is deterministic even for a
        // fast local operation.
        let id = await queue.submit(.createFolder(at: root, name: "Cancelled"))
        let cancelled = await queue.cancel(id)
        if cancelled {
            var cancelledSnapshot: FileOperationQueueSnapshot?
            for _ in 0..<100 {
                cancelledSnapshot = await queue.snapshot(for: id)
                if cancelledSnapshot?.state == .cancelled { break }
                await Task.yield()
            }
            XCTAssertEqual(cancelledSnapshot?.state, .cancelled)
            do {
                _ = try await queue.result(for: id)
                XCTFail("Expected cancellation")
            } catch let error as FileOperationError {
                XCTAssertEqual(error, .cancelled)
            }
        } else {
            let completedSnapshot = await queue.snapshot(for: id)
            XCTAssertEqual(completedSnapshot?.state, .completed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cancelled").path))
    }

    func testQueuePublishesBoundedStateAndProgressEvents() async throws {
        let queue = FileOperationQueue(bufferSize: 4)
        var iterator = queue.events.makeAsyncIterator()
        let id = await queue.submit(.createFolder(at: root, name: "Events"))
        var states: [FileOperationQueueState] = []
        var sawProgress = false
        while let event = await iterator.next() {
            switch event {
            case .stateChanged(let snapshot) where snapshot.id == id:
                states.append(snapshot.state)
                if snapshot.state == .completed { break }
            case .progress(let progress) where progress.id == id:
                sawProgress = true
            default:
                break
            }
            if states.last == .completed { break }
        }
        XCTAssertEqual(states.first, .queued)
        XCTAssertTrue(states.contains(.running))
        XCTAssertEqual(states.last, .completed)
        XCTAssertTrue(sawProgress)
    }

    func testInteractiveConflictsCanSkipKeepBothReplaceAndStop() async throws {
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let one = root.appendingPathComponent("one.txt")
        let two = root.appendingPathComponent("two.txt")
        let three = root.appendingPathComponent("three.txt")
        let four = root.appendingPathComponent("four.txt")
        try Data("1".utf8).write(to: one)
        try Data("2".utf8).write(to: two)
        try Data("3".utf8).write(to: three)
        try Data("4".utf8).write(to: four)
        try Data("old1".utf8).write(to: destination.appendingPathComponent("one.txt"))
        try Data("old2".utf8).write(to: destination.appendingPathComponent("two.txt"))
        try Data("old3".utf8).write(to: destination.appendingPathComponent("three.txt"))
        try Data("old4".utf8).write(to: destination.appendingPathComponent("four.txt"))

        let resolver = ScriptedFileConflictResolver(responses: [.skip, .keepBoth, .replace, .stop])
        let result = try await engine.execute(
            .copy(sources: [one, two, three, four], to: destination, conflictPolicy: .ask),
            conflictResolver: resolver
        )

        XCTAssertEqual(result.completedItems, 2)
        XCTAssertEqual(result.skippedItems, 2)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("one.txt")), "old1")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("two copy.txt")), "2")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("three.txt")), "3")
        XCTAssertTrue(result.items[2].replacedExisting)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("four.txt")), "old4")
        let promptCount = await resolver.promptCount()
        XCTAssertEqual(promptCount, 4)
    }

    func testAskWithoutResolverFailsLikeTheDefaultPolicy() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        try Data("new".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("source.txt"))
        do {
            _ = try await engine.execute(.copy(sources: [source], to: destination, conflictPolicy: .ask))
            XCTFail("Expected a conflict")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .destinationExists(destination.appendingPathComponent("source.txt")))
        }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("source.txt")), "old")
    }

    func testCopyReportsByteProgressFromTheFileManagerClient() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        try Data("hello".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let client = ChunkedCopyFileManager()
        let progressEngine = FileOperationEngine(fileManager: client)
        let recorded = ProgressBytes()
        _ = try await progressEngine.execute(
            .copy(sources: [source], to: destination),
            asyncProgress: { progress in recorded.append(progress.completedBytes) }
        )
        let bytes = recorded.values
        XCTAssertTrue(bytes.contains(40))
        XCTAssertTrue(bytes.contains(100))
        XCTAssertEqual(bytes.last, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source.txt").path))
    }

    func testQueueForwardsInteractiveConflictResolver() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("Out", isDirectory: true)
        try Data("new".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("source.txt"))
        let queue = FileOperationQueue()
        let resolver = ScriptedFileConflictResolver(responses: [.keepBoth])
        let id = await queue.submit(
            .copy(sources: [source], to: destination, conflictPolicy: .ask),
            conflictResolver: resolver
        )
        let result = try await queue.result(for: id)
        XCTAssertEqual(result.completedItems, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("source copy.txt").path))
        let promptCount = await resolver.promptCount()
        XCTAssertEqual(promptCount, 1)
    }
}

/// For safety this test records the trash request instead of moving anything
/// into the user's system Trash. All other filesystem calls still use the
/// temporary-directory-backed production client.
private final class TrashRecordingFileManager: FileManagerClient, @unchecked Sendable {
    private let backing = LocalFileManagerClient()
    private(set) var trashed: [URL] = []
    let resultingURL = URL(fileURLWithPath: "/tmp/ExplorerTestTrash/trash-me.txt")

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        backing.fileExists(atPath: path, isDirectory: isDirectory)
    }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try backing.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    func copyItem(at srcURL: URL, to dstURL: URL) throws { try backing.copyItem(at: srcURL, to: dstURL) }
    func moveItem(at srcURL: URL, to dstURL: URL) throws { try backing.moveItem(at: srcURL, to: dstURL) }
    func removeItem(at URL: URL) throws { try backing.removeItem(at: URL) }
    func volumeIdentifier(for url: URL) throws -> String? { try backing.volumeIdentifier(for: url) }
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        trashed.append(url)
        resultingItemURL?.pointee = resultingURL as NSURL
    }
}

private final class FailingCopyFileManager: FileManagerClient, @unchecked Sendable {
    private let backing = LocalFileManagerClient()
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        backing.fileExists(atPath: path, isDirectory: isDirectory)
    }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try backing.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "ExplorerOperationsTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "injected copy failure"])
    }
    func moveItem(at srcURL: URL, to dstURL: URL) throws { try backing.moveItem(at: srcURL, to: dstURL) }
    func removeItem(at URL: URL) throws { try backing.removeItem(at: URL) }
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try backing.trashItem(at: url, resultingItemURL: resultingItemURL)
    }
    func volumeIdentifier(for url: URL) throws -> String? { try backing.volumeIdentifier(for: url) }
}

private final class ProgressBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

actor ScriptedFileConflictResolver: FileConflictResolving {
    private var responses: [FileConflictResolution]
    private(set) var prompts: [FileConflict] = []

    init(responses: [FileConflictResolution]) {
        self.responses = responses
    }

    func resolve(_ conflict: FileConflict) async -> FileConflictResolution {
        prompts.append(conflict)
        if responses.isEmpty { return .stop }
        return responses.removeFirst()
    }

    func promptCount() -> Int { prompts.count }
}

private final class ChunkedCopyFileManager: FileManagerClient, @unchecked Sendable {
    private let backing = LocalFileManagerClient()
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        backing.fileExists(atPath: path, isDirectory: isDirectory)
    }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                         attributes: [FileAttributeKey: Any]?) throws {
        try backing.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    func copyItem(at srcURL: URL, to dstURL: URL) throws { try backing.copyItem(at: srcURL, to: dstURL) }
    func copyItemWithProgress(
        at srcURL: URL,
        to dstURL: URL,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        await onBytesCopied(40)
        await onBytesCopied(100)
        try copyItem(at: srcURL, to: dstURL)
    }
    func byteCount(of url: URL) -> Int64 { 100 }
    func moveItem(at srcURL: URL, to dstURL: URL) throws { try backing.moveItem(at: srcURL, to: dstURL) }
    func removeItem(at URL: URL) throws { try backing.removeItem(at: URL) }
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try backing.trashItem(at: url, resultingItemURL: resultingItemURL)
    }
    func volumeIdentifier(for url: URL) throws -> String? { try backing.volumeIdentifier(for: url) }
}
