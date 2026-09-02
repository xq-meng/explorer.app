import Foundation
import XCTest
@testable import ExplorerOperations

final class FileCoordinationTests: XCTestCase {
    func testLocalFileManagerCoordinatesEveryMutationShape() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerCoordination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = RecordingFileCoordinator()
        let client = LocalFileManagerClient(fileManager: .default, coordinator: recorder)
        let directory = root.appendingPathComponent("Directory", isDirectory: true)
        try client.createDirectory(at: directory, withIntermediateDirectories: false, attributes: nil)

        let source = root.appendingPathComponent("source.txt")
        let copied = directory.appendingPathComponent("copied.txt")
        let moved = root.appendingPathComponent("moved.txt")
        try Data("coordinated".utf8).write(to: source)
        try await client.copyItemWithProgress(at: source, to: copied) { _ in }
        try client.moveItem(at: copied, to: moved)
        try client.removeItem(at: moved)

        XCTAssertEqual(recorder.events, [
            .write(directory, .createOrModify),
            .readWrite(source, copied, .createOrModify),
            .move(copied, moved),
            .write(moved, .delete),
        ])
    }

    func testConditionalMoveRevalidatesIdentityInsideCoordination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerConditionalMove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("destination.txt")
        let backup = root.appendingPathComponent("backup.txt")
        try Data("original".utf8).write(to: source)
        let fingerprint = try FileOperationFingerprint.capture(at: source)
        let coordinator = ReplacingMoveSourceCoordinator(replacement: Data("external".utf8))
        let client = LocalFileManagerClient(fileManager: .default, coordinator: coordinator)

        XCTAssertThrowsError(
            try client.moveItem(at: source, to: backup, onlyIfMatches: fingerprint)
        )
        XCTAssertEqual(try String(contentsOf: source), "external")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testConditionalRemoveRevalidatesIdentityInsideCoordination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerConditionalRemove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let fingerprint = try FileOperationFingerprint.capture(at: source)
        let coordinator = ReplacingWriteSourceCoordinator(replacement: Data("external".utf8))
        let client = LocalFileManagerClient(fileManager: .default, coordinator: coordinator)

        XCTAssertThrowsError(try client.removeItem(at: source, onlyIfMatches: fingerprint))
        XCTAssertEqual(try String(contentsOf: source), "external")
    }
}

private struct ReplacingMoveSourceCoordinator: FileCoordinationClient, Sendable {
    let replacement: Data

    func coordinateWriting(
        at url: URL,
        intent: CoordinatedWriteIntent,
        accessor: (URL) throws -> Void
    ) throws {
        try accessor(url)
    }

    func coordinateReading(
        at source: URL,
        writingAt destination: URL,
        destinationIntent: CoordinatedWriteIntent,
        accessor: (URL, URL) throws -> Void
    ) throws {
        try accessor(source, destination)
    }

    func coordinateMoving(
        from source: URL,
        to destination: URL,
        accessor: (URL, URL) throws -> Void
    ) throws {
        try FileManager.default.removeItem(at: source)
        try replacement.write(to: source)
        try accessor(source, destination)
    }
}

private struct ReplacingWriteSourceCoordinator: FileCoordinationClient, Sendable {
    let replacement: Data

    func coordinateWriting(
        at url: URL,
        intent: CoordinatedWriteIntent,
        accessor: (URL) throws -> Void
    ) throws {
        try FileManager.default.removeItem(at: url)
        try replacement.write(to: url)
        try accessor(url)
    }

    func coordinateReading(
        at source: URL,
        writingAt destination: URL,
        destinationIntent: CoordinatedWriteIntent,
        accessor: (URL, URL) throws -> Void
    ) throws {
        try accessor(source, destination)
    }

    func coordinateMoving(
        from source: URL,
        to destination: URL,
        accessor: (URL, URL) throws -> Void
    ) throws {
        try accessor(source, destination)
    }
}

private final class RecordingFileCoordinator: FileCoordinationClient, @unchecked Sendable {
    enum Event: Equatable {
        case write(URL, CoordinatedWriteIntent)
        case readWrite(URL, URL, CoordinatedWriteIntent)
        case move(URL, URL)
    }

    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func coordinateWriting(
        at url: URL,
        intent: CoordinatedWriteIntent,
        accessor: (URL) throws -> Void
    ) throws {
        record(.write(url, intent))
        try accessor(url)
    }

    func coordinateReading(
        at source: URL,
        writingAt destination: URL,
        destinationIntent: CoordinatedWriteIntent,
        accessor: (URL, URL) throws -> Void
    ) throws {
        record(.readWrite(source, destination, destinationIntent))
        try accessor(source, destination)
    }

    func coordinateMoving(
        from source: URL,
        to destination: URL,
        accessor: (URL, URL) throws -> Void
    ) throws {
        record(.move(source, destination))
        try accessor(source, destination)
    }

    private func record(_ event: Event) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}
