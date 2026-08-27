import Foundation
import XCTest
import ExplorerCore
@testable import ExplorerBrowsing

final class LocalFileProviderTests: XCTestCase {
    func testLoadFiltersHiddenItemsAndKeepsDirectoriesFirstWhenDescending() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let visible = root.appendingPathComponent("visible.txt")
        let hidden = root.appendingPathComponent(".hidden.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("visible".utf8).write(to: visible)
        try Data("hidden".utf8).write(to: hidden)

        let provider = LocalFileProvider()
        let snapshot = try await provider.loadDirectory(
            at: root,
            options: DirectoryLoadOptions(
                showsHiddenFiles: false,
                sortDescriptor: FileSortDescriptor(
                    field: .name,
                    direction: .descending,
                    directoriesFirst: true
                )
            )
        )

        XCTAssertEqual(snapshot.items.map(\.name), ["Folder", "visible.txt"])
        XCTAssertEqual(snapshot.items.first?.kind, .directory)
        XCTAssertFalse(snapshot.items.contains(where: \.isHidden))
    }

    func testLoadCanIncludeHiddenItems() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".hidden"))

        let snapshot = try await LocalFileProvider().loadDirectory(
            at: root,
            options: DirectoryLoadOptions(showsHiddenFiles: true)
        )

        XCTAssertEqual(snapshot.items.map(\.name), [".hidden"])
        XCTAssertEqual(snapshot.items.first?.isHidden, true)
    }

    func testLoadingAFileReportsNotDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("item.txt")
        try Data().write(to: file)

        do {
            _ = try await LocalFileProvider().loadDirectory(at: file)
            XCTFail("Expected a not-directory error")
        } catch let error as FileProviderError {
            XCTAssertEqual(error, .notDirectory(file.standardizedFileURL))
        }
    }

    func testCancelledLoadDoesNotReturnSnapshot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = LocalFileProvider()

        let task = Task {
            try await provider.loadDirectory(at: root)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as FileProviderError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
