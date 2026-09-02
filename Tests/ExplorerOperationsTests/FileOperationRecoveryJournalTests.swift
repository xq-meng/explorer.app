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

    func testRecoveryPreservesAmbiguousLegacyReplacementItems() async throws {
        let destination = root.appendingPathComponent("report.txt")
        let transactionID = UUID()
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("original".utf8).write(to: destination)

        let id = try await journal.begin(id: transactionID, destination: destination, backup: backup)
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try Data("partial replacement".utf8).write(to: destination)

        let report = await journal.recoverPendingTransactions()

        XCTAssertTrue(report.restoredDestinations.isEmpty)
        XCTAssertTrue(report.finalizedDestinations.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: destination), "partial replacement")
        XCTAssertEqual(try String(contentsOf: backup), "original")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 1)
    }

    func testRecoveryPreservesAnUnverifiableLegacyCompletedBackup() async throws {
        let destination = root.appendingPathComponent("report.txt")
        let transactionID = UUID()
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("original".utf8).write(to: destination)

        let id = try await journal.begin(id: transactionID, destination: destination, backup: backup)
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try Data("replacement".utf8).write(to: destination)
        try await journal.markReplacementCompleted(id)

        let report = await journal.recoverPendingTransactions()

        XCTAssertTrue(report.restoredDestinations.isEmpty)
        XCTAssertTrue(report.finalizedDestinations.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertEqual(try String(contentsOf: backup), "original")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 1)
    }

    func testCompletedReplacementRestoresBackupWhenDestinationDisappeared() async throws {
        let destination = root.appendingPathComponent("report.txt")
        let transactionID = UUID()
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("original".utf8).write(to: destination)

        let id = try await journal.begin(id: transactionID, destination: destination, backup: backup)
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

    func testRecoveryDiscardsAnIncompleteStagedCopy() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        try Data("source".utf8).write(to: source)
        _ = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: nil,
            originalDestinationFingerprint: nil,
            removesSource: false
        )
        try Data("partial".utf8).write(to: staging)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.discardedTransfers, [destination])
        XCTAssertTrue(report.completedTransfers.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryRecognizesAStagedCopyCommittedBeforeItsJournalUpdate() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        try Data("complete".utf8).write(to: source)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: nil,
            originalDestinationFingerprint: nil,
            removesSource: false
        )
        try FileManager.default.copyItem(at: source, to: staging)
        try await journal.markStagedCopyCompleted(
            id,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            stagingFingerprint: FileOperationFingerprint.capture(at: staging)
        )
        try FileManager.default.moveItem(at: staging, to: destination)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.completedTransfers, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "complete")
        XCTAssertEqual(try String(contentsOf: source), "complete")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryCommitsACompletedNonreplacementStage() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        try Data("complete".utf8).write(to: source)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: nil,
            originalDestinationFingerprint: nil,
            removesSource: false
        )
        try FileManager.default.copyItem(at: source, to: staging)
        try await journal.markStagedCopyCompleted(
            id,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            stagingFingerprint: FileOperationFingerprint.capture(at: staging)
        )

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.completedTransfers, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try String(contentsOf: destination), "complete")
    }

    func testRecoveryCompletesACommittedCrossVolumeMove() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("moved.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        try Data("complete".utf8).write(to: source)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: nil,
            originalDestinationFingerprint: nil,
            removesSource: true
        )
        try FileManager.default.copyItem(at: source, to: staging)
        try await journal.markStagedCopyCompleted(
            id,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            stagingFingerprint: FileOperationFingerprint.capture(at: staging)
        )
        try FileManager.default.moveItem(at: staging, to: destination)
        try await journal.markDestinationCommitted(id)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.completedTransfers, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination), "complete")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryCompletesSourceDeletionPreparedAndSourceRemovedPhases() async throws {
        for sourceWasRemoved in [false, true] {
            let transactionID = UUID()
            let source = root.appendingPathComponent("source-\(transactionID).txt")
            let destination = root.appendingPathComponent("moved-\(transactionID).txt")
            let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
            try Data("complete".utf8).write(to: source)
            let id = try await journal.beginStagedTransfer(
                id: transactionID,
                source: source,
                destination: destination,
                staging: staging,
                backup: nil,
                originalDestinationFingerprint: nil,
                removesSource: true
            )
            try FileManager.default.copyItem(at: source, to: staging)
            try await journal.markStagedCopyCompleted(
                id,
                sourceFingerprint: FileOperationFingerprint.capture(at: source),
                stagingFingerprint: FileOperationFingerprint.capture(at: staging)
            )
            try FileManager.default.moveItem(at: staging, to: destination)
            try await journal.markDestinationCommitted(id)
            try await journal.markSourceDeletionPrepared(id)
            if sourceWasRemoved {
                try FileManager.default.removeItem(at: source)
                try await journal.markSourceRemoved(id)
            }

            let report = await journal.recoverPendingTransactions()

            XCTAssertEqual(report.completedTransfers, [destination])
            XCTAssertTrue(report.failures.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try String(contentsOf: destination), "complete")
        }
        let secondReport = await journal.recoverPendingTransactions()
        XCTAssertFalse(secondReport.didFindPendingWork)
    }

    func testRecoveryPreservesAChangedCrossVolumeMoveSource() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("moved.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        try Data("original".utf8).write(to: source)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: nil,
            originalDestinationFingerprint: nil,
            removesSource: true
        )
        try FileManager.default.copyItem(at: source, to: staging)
        try await journal.markStagedCopyCompleted(
            id,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            stagingFingerprint: FileOperationFingerprint.capture(at: staging)
        )
        try FileManager.default.moveItem(at: staging, to: destination)
        try await journal.markDestinationCommitted(id)
        try Data("changed after copy".utf8).write(to: source)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: source), "changed after copy")
        XCTAssertEqual(try String(contentsOf: destination), "original")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 1)
    }

    func testRecoveryRestoresReplacementAndDiscardsItsPartialStage() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let originalFingerprint = try FileOperationFingerprint.capture(at: destination)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: backup,
            originalDestinationFingerprint: originalFingerprint,
            removesSource: false
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try Data("partial".utf8).write(to: staging)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.discardedTransfers, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryDiscardsCompletedReplacementStageBeforeBackupBegins() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: backup,
            originalDestinationFingerprint: FileOperationFingerprint.capture(at: destination),
            removesSource: false
        )
        try FileManager.default.copyItem(at: source, to: staging)
        try await journal.markStagedCopyCompleted(
            id,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            stagingFingerprint: FileOperationFingerprint.capture(at: staging)
        )

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.discardedTransfers, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryRecognizesReplacementStageCommitBeforeDestinationMark() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let transactionID = UUID()
        let staging = root.appendingPathComponent(".explorer-stage-\(transactionID.uuidString)")
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let id = try await journal.beginStagedTransfer(
            id: transactionID,
            source: source,
            destination: destination,
            staging: staging,
            backup: backup,
            originalDestinationFingerprint: FileOperationFingerprint.capture(at: destination),
            removesSource: false
        )
        try FileManager.default.copyItem(at: source, to: staging)
        try await journal.markStagedCopyCompleted(
            id,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            stagingFingerprint: FileOperationFingerprint.capture(at: staging)
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try FileManager.default.moveItem(at: staging, to: destination)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.completedTransfers, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testDirectoryFingerprintChangesWhenADescendantChanges() throws {
        let directory = root.appendingPathComponent("Folder", isDirectory: true)
        let child = directory.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("before".utf8).write(to: child)
        let before = try FileOperationFingerprint.capture(at: directory)

        try Data("changed descendant contents".utf8).write(to: child)

        XCTAssertNotEqual(try FileOperationFingerprint.capture(at: directory), before)
    }

    func testRecoveryRecognizesAReplacementMoveCommittedBeforeItsJournalUpdate() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        let transactionID = UUID()
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let sourceFingerprint = try FileOperationFingerprint.capture(at: source)
        let originalFingerprint = try FileOperationFingerprint.capture(at: destination)
        let id = try await journal.beginReplacementMove(
            id: transactionID,
            source: source,
            destination: destination,
            backup: backup,
            sourceFingerprint: sourceFingerprint,
            originalDestinationFingerprint: originalFingerprint
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try await journal.markSourceMovePrepared(id)
        try FileManager.default.moveItem(at: source, to: destination)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.finalizedDestinations, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: destination), "new")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }

    func testRecoveryRollsBackAReplacementMoveBeforeSourceCommit() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("destination.txt")
        let transactionID = UUID()
        let backup = root.appendingPathComponent(".explorer-replace-\(transactionID.uuidString)")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let id = try await journal.beginReplacementMove(
            id: transactionID,
            source: source,
            destination: destination,
            backup: backup,
            sourceFingerprint: FileOperationFingerprint.capture(at: source),
            originalDestinationFingerprint: FileOperationFingerprint.capture(at: destination)
        )
        try FileManager.default.moveItem(at: destination, to: backup)
        try await journal.markBackupCreated(id)
        try await journal.markSourceMovePrepared(id)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.restoredDestinations, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: source), "new")
        XCTAssertEqual(try String(contentsOf: destination), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
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

    func testRecoveryRejectsATransferPathThatDoesNotMatchItsTransactionID() async throws {
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let unrelated = root.appendingPathComponent(".explorer-stage-unrelated")
        try Data("source".utf8).write(to: source)
        try Data("must survive".utf8).write(to: unrelated)
        _ = try await journal.beginStagedTransfer(
            id: UUID(),
            source: source,
            destination: destination,
            staging: unrelated,
            backup: nil,
            originalDestinationFingerprint: nil,
            removesSource: false
        )

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(try String(contentsOf: unrelated), "must survive")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 1)
    }

    func testRecoveryRemainsCompatibleWithPre080ReplacementJournal() async throws {
        let destination = root.appendingPathComponent("destination.txt")
        let backup = root.appendingPathComponent(".explorer-replace-legacy")
        try Data("old".utf8).write(to: backup)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let legacy = LegacyReplacementEntry(
            id: UUID(),
            destination: destination,
            backup: backup,
            startedAt: Date(),
            phase: "backupCreated"
        )
        let journalURL = journalDirectory
            .appendingPathComponent(legacy.id.uuidString)
            .appendingPathExtension("json")
        try JSONEncoder().encode(legacy).write(to: journalURL)

        let report = await journal.recoverPendingTransactions()

        XCTAssertEqual(report.restoredDestinations, [destination])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try String(contentsOf: destination), "old")
        let pendingEntryCount = try await journal.pendingEntryCount()
        XCTAssertEqual(pendingEntryCount, 0)
    }
}

private struct LegacyReplacementEntry: Encodable {
    let id: UUID
    let destination: URL
    let backup: URL
    let startedAt: Date
    let phase: String
}
