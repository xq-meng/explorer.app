import XCTest
@testable import ExplorerOperations

final class FileOperationUndoPlannerTests: XCTestCase {
    func testCopyUndoTrashesOnlyCompletedDestinations() {
        let source = URL(fileURLWithPath: "/source/report.txt")
        let destination = URL(fileURLWithPath: "/destination/report copy.txt")
        let operation = FileOperation.copy(sources: [source], to: destination.deletingLastPathComponent(), conflictPolicy: .keepBoth)
        let result = FileOperationResult(kind: .copy, items: [
            .init(source: source, destination: destination, status: .completed),
        ])

        let plan = FileOperationUndoPlanner.plan(for: operation, result: result)
        XCTAssertEqual(plan?.actionName, "Copy")
        XCTAssertEqual(plan?.undoOperations, [.trash(sources: [destination])])
        XCTAssertEqual(plan?.redoOperations, [operation])
    }

    func testMoveUndoRestoresOriginalParentAndName() {
        let source = URL(fileURLWithPath: "/original/report.txt")
        let destination = URL(fileURLWithPath: "/target/report copy.txt")
        let operation = FileOperation.move(
            sources: [source],
            to: destination.deletingLastPathComponent(),
            conflictPolicy: .keepBoth
        )
        let result = FileOperationResult(kind: .move, items: [
            .init(source: source, destination: destination, status: .completed),
        ])

        let plan = FileOperationUndoPlanner.plan(for: operation, result: result)
        XCTAssertEqual(plan?.undoOperations, [
            .move(sources: [destination], to: source.deletingLastPathComponent(), conflictPolicy: .fail),
            .rename(
                source: source.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent),
                name: source.lastPathComponent,
                conflictPolicy: .fail
            ),
        ])
    }

    func testTrashNeedsSystemResultLocationToBecomeUndoable() {
        let source = URL(fileURLWithPath: "/original/report.txt")
        let operation = FileOperation.trash(sources: [source])
        let missingLocation = FileOperationResult(kind: .trash, items: [
            .init(source: source, destination: nil, status: .completed),
        ])
        XCTAssertNil(FileOperationUndoPlanner.plan(for: operation, result: missingLocation))

        let trashURL = URL(fileURLWithPath: "/.Trash/report.txt")
        let capturedLocation = FileOperationResult(kind: .trash, items: [
            .init(source: source, destination: trashURL, status: .completed),
        ])
        XCTAssertEqual(
            FileOperationUndoPlanner.plan(for: operation, result: capturedLocation)?.undoOperations,
            [.move(sources: [trashURL], to: source.deletingLastPathComponent(), conflictPolicy: .fail)]
        )
    }

    func testReplaceOperationsAreNotOfferedAsUndoable() {
        let source = URL(fileURLWithPath: "/source/report.txt")
        let destination = URL(fileURLWithPath: "/destination/report.txt")
        let operation = FileOperation.copy(
            sources: [source],
            to: destination.deletingLastPathComponent(),
            conflictPolicy: .replace
        )
        let result = FileOperationResult(kind: .copy, items: [
            .init(source: source, destination: destination, status: .completed),
        ])
        XCTAssertNil(FileOperationUndoPlanner.plan(for: operation, result: result))
    }

    func testMoveUndoAndRedoRoundTripThroughSafetyEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerUndoRoundTrip-\(UUID().uuidString)", isDirectory: true)
        let originalDirectory = root.appendingPathComponent("Original", isDirectory: true)
        let targetDirectory = root.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = originalDirectory.appendingPathComponent("report.txt")
        try Data("undo round trip".utf8).write(to: source)
        let operation = FileOperation.move(sources: [source], to: targetDirectory)
        let engine = FileOperationEngine()
        let result = try await engine.execute(operation)
        let plan = try XCTUnwrap(FileOperationUndoPlanner.plan(for: operation, result: result))

        for inverse in plan.undoOperations { _ = try await engine.execute(inverse) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("report.txt").path))

        for redo in plan.redoOperations { _ = try await engine.execute(redo) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("report.txt").path))
    }
}
