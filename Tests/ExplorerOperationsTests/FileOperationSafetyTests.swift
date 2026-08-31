import Foundation
import XCTest
@testable import ExplorerOperations

final class FileOperationSafetyTests: XCTestCase {
    private var root: URL!
    private var engine: FileOperationEngine!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        engine = FileOperationEngine()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testInvalidNamesAreRejected() async throws {
        for invalidName in ["", ".", "..", "nested/name", "bad\0name"] {
            do {
                _ = try await engine.execute(.createFolder(at: root, name: invalidName))
                XCTFail("Expected invalid name: \(invalidName.debugDescription)")
            } catch let error as FileOperationError {
                XCTAssertEqual(error, .invalidName(invalidName))
            }
        }
    }

    func testCopyAndMoveCannotPutDirectoryInsideItself() async throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let descendant = source.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        for operation in [
            FileOperation.copy(sources: [source], to: descendant),
            FileOperation.move(sources: [source], to: descendant)
        ] {
            do {
                _ = try await engine.execute(operation)
                XCTFail("Expected descendant destination rejection")
            } catch let error as FileOperationError {
                if case .invalidDestination = error {} else { XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSymlinkedDestinationInsideDirectoryIsRejectedBeforeMutation() async throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let child = source.appendingPathComponent("Child", isDirectory: true)
        let link = root.appendingPathComponent("DestinationLink", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)

        for operation in [
            FileOperation.copy(sources: [source], to: link),
            FileOperation.move(sources: [source], to: link)
        ] {
            do {
                _ = try await engine.execute(operation)
                XCTFail("Expected canonical descendant rejection")
            } catch let error as FileOperationError {
                if case .invalidDestination = error {} else { XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }

    func testSiblingWithCommonPrefixRemainsAllowed() async throws {
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let sibling = root.appendingPathComponent("SourceArchive", isDirectory: true)
        let item = source.appendingPathComponent("item.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        try Data("safe".utf8).write(to: item)

        _ = try await engine.execute(.copy(sources: [source], to: sibling))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.appendingPathComponent("Source/item.txt").path))
    }

    func testSameSourceAndDestinationIsRejected() async throws {
        let source = root.appendingPathComponent("item.txt")
        try Data("safe".utf8).write(to: source)
        do {
            _ = try await engine.execute(.copy(sources: [source], to: root))
            XCTFail("Expected same destination rejection")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .sameSourceAndDestination(source))
        }
        XCTAssertEqual(try String(contentsOf: source), "safe")
    }

    func testKeepBothPreservesExtensionAndFindsRepeatedName() async throws {
        let source = root.appendingPathComponent("report.txt")
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try Data("new".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("report.txt"))
        try Data("older".utf8).write(to: destination.appendingPathComponent("report copy.txt"))

        _ = try await engine.execute(.copy(sources: [source], to: destination, conflictPolicy: .keepBoth))
        let repeated = destination.appendingPathComponent("report copy 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repeated.path))
        XCTAssertEqual(try String(contentsOf: repeated), "new")
    }

    func testRenameReplaceRestoresExistingDestinationWhenRenameFails() async throws {
        let source = root.appendingPathComponent("source.txt")
        let existing = root.appendingPathComponent("existing.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)
        let client = FailSecondMoveClient()
        let journal = FileOperationRecoveryJournal(
            directory: root.appendingPathComponent("RecoveryJournal", isDirectory: true)
        )
        do {
            _ = try await FileOperationEngine(fileManager: client, recoveryJournal: journal).execute(
                .rename(source: source, name: "existing.txt", conflictPolicy: .replace)
            )
            XCTFail("Expected injected rename failure")
        } catch {
            XCTAssertEqual(try String(contentsOf: source), "source")
            XCTAssertEqual(try String(contentsOf: existing), "existing")
            let pendingEntryCount = try await journal.pendingEntryCount()
            XCTAssertEqual(pendingEntryCount, 0)
        }
    }

    func testMissingSourceAndDestinationAreReported() async throws {
        let source = root.appendingPathComponent("missing.txt")
        do {
            _ = try await engine.execute(.copy(sources: [source], to: root))
            XCTFail("Expected missing source")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .sourceMissing(source))
        }

        let existing = root.appendingPathComponent("existing.txt")
        try Data("data".utf8).write(to: existing)
        let missingDirectory = root.appendingPathComponent("missing-directory")
        do {
            _ = try await engine.execute(.copy(sources: [existing], to: missingDirectory))
            XCTFail("Expected missing destination")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .destinationMissing(missingDirectory))
        }
    }

    func testPartiallyCompletedBatchLeavesCompletedItemsIntact() async throws {
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let client = FailCopyForFilenameClient(failingName: second.lastPathComponent)
        do {
            _ = try await FileOperationEngine(fileManager: client).execute(
                .copy(sources: [first, second], to: destination)
            )
            XCTFail("Expected second item failure")
        } catch {
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("first.txt")), "one")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("second.txt").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        }
    }
}

private final class FailSecondMoveClient: FileManagerClient, @unchecked Sendable {
    private let backing = LocalFileManagerClient()
    private var moveCount = 0
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool { backing.fileExists(atPath: path, isDirectory: isDirectory) }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws { try backing.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes) }
    func copyItem(at srcURL: URL, to dstURL: URL) throws { try backing.copyItem(at: srcURL, to: dstURL) }
    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == 2 { throw NSError(domain: "SafetyTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "rename failure"]) }
        try backing.moveItem(at: srcURL, to: dstURL)
    }
    func removeItem(at URL: URL) throws { try backing.removeItem(at: URL) }
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws { try backing.trashItem(at: url, resultingItemURL: resultingItemURL) }
    func volumeIdentifier(for url: URL) throws -> String? { try backing.volumeIdentifier(for: url) }
}

private final class FailCopyForFilenameClient: FileManagerClient, @unchecked Sendable {
    private let backing = LocalFileManagerClient()
    private let failingName: String
    init(failingName: String) { self.failingName = failingName }
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool { backing.fileExists(atPath: path, isDirectory: isDirectory) }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws { try backing.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes) }
    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == failingName { throw NSError(domain: "SafetyTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "copy failure"]) }
        try backing.copyItem(at: srcURL, to: dstURL)
    }
    func moveItem(at srcURL: URL, to dstURL: URL) throws { try backing.moveItem(at: srcURL, to: dstURL) }
    func removeItem(at URL: URL) throws { try backing.removeItem(at: URL) }
    func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws { try backing.trashItem(at: url, resultingItemURL: resultingItemURL) }
    func volumeIdentifier(for url: URL) throws -> String? { try backing.volumeIdentifier(for: url) }
}
