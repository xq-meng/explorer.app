import ExplorerUI
import Foundation
import XCTest
@testable import ExplorerApp

final class ExplorerOpenURLResolverTests: XCTestCase {
    func testDirectoryURLOpensThatDirectory() throws {
        let directory = try temporaryDirectory()
        XCTAssertEqual(
            ExplorerOpenURLResolver.locations(for: [directory]),
            [.directory(directory.standardizedFileURL)]
        )
    }

    func testFileURLOpensTheParentDirectory() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(
            ExplorerOpenURLResolver.locations(for: [file]),
            [.directory(directory.standardizedFileURL)]
        )
    }

    func testDuplicatePathsCollapseToOneLocation() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("note.txt")
        try Data().write(to: file)
        XCTAssertEqual(
            ExplorerOpenURLResolver.locations(for: [directory, file, directory]),
            [.directory(directory.standardizedFileURL)]
        )
    }

    func testNonFileURLsAreIgnored() {
        XCTAssertTrue(
            ExplorerOpenURLResolver.locations(for: [URL(string: "https://example.com")!]).isEmpty
        )
    }

    func testMissingDirectoryPathStillOpensAsDirectory() {
        let missing = URL(fileURLWithPath: "/tmp/explorer-missing-folder-\(UUID().uuidString)", isDirectory: true)
        XCTAssertEqual(
            ExplorerOpenURLResolver.locations(for: [missing]),
            [.directory(missing.standardizedFileURL)]
        )
    }

    func testMultipleDirectoriesOpenAsSeparateLocations() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        XCTAssertEqual(
            ExplorerOpenURLResolver.locations(for: [first, second]),
            [
                .directory(first.standardizedFileURL),
                .directory(second.standardizedFileURL),
            ]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerOpenURL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
