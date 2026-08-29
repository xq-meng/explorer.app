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

    func testCloudDocsListingDoesNotInjectSiblingAppLibraries() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mobileDocuments = root.appendingPathComponent("Mobile Documents", isDirectory: true)
        let cloudDocs = mobileDocuments.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        let stash = mobileDocuments.appendingPathComponent("iCloud~ws~stash~icloud", isDirectory: true)
        let stashDocuments = stash.appendingPathComponent("Documents", isDirectory: true)
        let pages = mobileDocuments.appendingPathComponent("com~apple~Pages", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudDocs.appendingPathComponent("QQ", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stashDocuments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: stashDocuments.appendingPathComponent("Default.yaml"))

        let snapshot = try await LocalFileProvider().loadDirectory(at: cloudDocs)
        XCTAssertEqual(snapshot.items.map(\.name), ["QQ"])
        XCTAssertFalse(snapshot.items.contains(where: { $0.name == "stash" }))

        let overlay = ICloudDriveLibraries.overlayItems(at: cloudDocs, showsHiddenFiles: false)
        XCTAssertEqual(overlay.map(\.name), ["stash"])
        XCTAssertEqual(overlay.first?.url, stashDocuments.standardizedFileURL)
        XCTAssertEqual(overlay.first?.kind, .directory)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
