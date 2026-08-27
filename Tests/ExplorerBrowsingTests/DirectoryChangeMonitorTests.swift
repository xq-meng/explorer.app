import Foundation
import XCTest
@testable import ExplorerBrowsing

final class DirectoryChangeMonitorTests: XCTestCase {
    func testRejectsRegularFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("item.txt")
        try Data().write(to: file)

        let monitor = DirectoryChangeMonitor()
        do {
            _ = try await monitor.invalidations(at: file)
            XCTFail("Expected a not-directory error")
        } catch let error as DirectoryChangeMonitorError {
            XCTAssertEqual(error, .notDirectory(file.standardizedFileURL))
        }
    }

    func testRejectsSymbolicLinkWithoutFollowingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target", isDirectory: true)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let monitor = DirectoryChangeMonitor()
        do {
            _ = try await monitor.invalidations(at: link)
            XCTFail("Expected a symbolic-link error")
        } catch let error as DirectoryChangeMonitorError {
            XCTAssertEqual(error, .symbolicLinkNotSupported(link.standardizedFileURL))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
