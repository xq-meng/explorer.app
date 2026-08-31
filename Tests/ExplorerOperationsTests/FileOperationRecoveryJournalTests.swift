import Foundation
import XCTest
@testable import ExplorerOperations

final class FileOperationRecoveryJournalTests: XCTestCase {
    private var root: URL!
    private var journalDirectory: URL!
    private var journal: FileOperationRecoveryJournal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerRecovery-\(UUID().uuidString)", isDirectory: true)
        journalDirectory = root.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        journal = FileOperationRecoveryJournal(directory: journalDirectory)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRecoveryRestoresOriginalAfterInterruptedReplacement() async throws {
        let destination = root.appendingPathComponent("report.txt")
        let backup = root.appendingPathComponent(".explorer-replace-test")
        try Data("original".utf8).write(to: destination)

        let id = try await journal.begin(destination: destination, backup: backup)
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try Data("partial replacement".utf8).write(to: destination)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.restoredDestinations, [destination])
        XCTAssertTrue(report.finalizedDestinations.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryFinalizesReplacementThatHadAlreadyCompleted() async throws {
        let destination = root.appendingPathComponent("report.txt")
        let backup = root.appendingPathComponent(".explorer-replace-test")
        try Data("original".utf8).write(to: destination)

        let id = try await journal.begin(destination: destination, backup: backup)
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try Data("replacement".utf8).write(to: destination)
        try await journal.markReplacementCompleted(id)

        let report = await journal.recoverPendingTransactions()

        XCTAssertTrue(report.restoredDestinations.isEmpty)
        XCTAssertEqual(report.finalizedDestinations, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testCompletedReplacementRestoresBackupWhenDestinationDisappeared() async throws {
        let destination = root.appendingPathComponent("report.txt")
        let backup = root.appendingPathComponent(".explorer-replace-test")
        try Data("original".utf8).write(to: destination)

        let id = try await journal.begin(destination: destination, backup: backup)
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try Data("replacement".utf8).write(to: destination)
        try await journal.markReplacementCompleted(id)
        try FileManager.default.removeItem(at: destination)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.restoredDestinations, [destination])
        XCTAssertTrue(report.finalizedDestinations.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testSuccessfulEngineReplacementClearsItsJournal() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destinationDirectory = root.appendingPathComponent("Destination", isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let engine = FileOperationEngine(recoveryJournal: journal)

        _ = try await engine.execute(
            .copy(sources: [source], to: destinationDirectory, conflictPolicy: .replace)
        )

        XCTAssertEqual(try String(contentsOf: destination), "new")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasPrefix(".explorer-replace-") }
        )
    }

    func testCorruptJournalIsRetainedAndReported() async throws {
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let corrupt = journalDirectory.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corrupt)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(
            report.failures.first?.journalURL.resolvingSymlinksInPath(),
            corrupt.resolvingSymlinksInPath()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }
}
