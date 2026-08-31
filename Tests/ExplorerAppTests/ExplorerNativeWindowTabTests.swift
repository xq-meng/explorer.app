import AppKit
import ExplorerOperations
import ExplorerUI
import XCTest
@testable import ExplorerApp

@MainActor
final class ExplorerNativeWindowTabTests: XCTestCase {
    func testQuickLookSelectionSnapshotSupportsConcurrentFrameworkReads() async {
        let snapshot = QuickLookSelectionSnapshot()
        let first = URL(fileURLWithPath: "/tmp/a.txt")
        let second = URL(fileURLWithPath: "/tmp/b.txt")
        snapshot.replace(with: [second, first])

        let reads = await withTaskGroup(of: [URL?].self, returning: [[URL?]].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    [snapshot.url(at: 0), snapshot.url(at: 1), snapshot.url(at: 2)]
                }
            }
            var values: [[URL?]] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(snapshot.count, 2)
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(reads.allSatisfy { $0 == [first, second, nil] })
    }

    func testWindowUsesTheNativeAppKitTabBar() throws {
        let controller = ExplorerWindowController()
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(window.tabbingMode, .preferred)
        XCTAssertEqual(window.tabbingIdentifier, "app.explorer.browser")
        XCTAssertEqual(window.tab.title, "Loading…")
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertTrue(window.contentViewController is ExplorerWindowContentViewController)
    }

    func testSystemNewTabActionPreservesTheBrowsingState() {
        let controller = ExplorerWindowController(
            initialState: ExplorerWindowState(
                location: .computer,
                viewMode: .icons,
                sortDescriptor: BrowserSortDescriptor(field: .modified, ascending: false)
            )
        )
        var requestedState: ExplorerWindowState?
        controller.onRequestNewTab = { requestedState = $0 }

        controller.newWindowForTab(nil)

        XCTAssertEqual(requestedState?.location, .computer)
        XCTAssertEqual(requestedState?.viewMode, .icons)
        XCTAssertEqual(
            requestedState?.sortDescriptor,
            BrowserSortDescriptor(field: .modified, ascending: false)
        )
    }

    func testExplorerWindowsCanJoinAnAppKitTabGroup() throws {
        let firstController = ExplorerWindowController()
        let secondController = ExplorerWindowController()
        let firstWindow = try XCTUnwrap(firstController.window)
        let secondWindow = try XCTUnwrap(secondController.window)

        firstWindow.addTabbedWindow(secondWindow, ordered: .above)
        defer { firstWindow.tabGroup?.removeWindow(secondWindow) }

        XCTAssertEqual(firstWindow.tabGroup?.windows.count, 2)
        XCTAssertTrue(firstWindow.tabGroup?.windows.contains { $0 === secondWindow } == true)
    }

    func testWindowTracksAndCancelsActiveFileOperationsBeforeClosing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerWindowOperations-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let source = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("pending".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let queue = FileOperationQueue(
            engine: FileOperationEngine(fileManager: WindowCancellableCopyFileManager())
        )
        let controller = ExplorerWindowController(operationQueue: queue)
        _ = await queue.submit(.copy(sources: [source], to: destination))

        for _ in 0..<100 {
            if controller.hasActiveFileOperations { break }
            await Task.yield()
        }
        XCTAssertTrue(controller.hasActiveFileOperations)

        await controller.cancelActiveFileOperationsAndWait()
        for _ in 0..<100 {
            if !controller.hasActiveFileOperations { break }
            await Task.yield()
        }
        XCTAssertFalse(controller.hasActiveFileOperations)
    }
}

private final class WindowCancellableCopyFileManager: FileManagerClient, @unchecked Sendable {
    private let backing = LocalFileManagerClient()

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        backing.fileExists(atPath: path, isDirectory: isDirectory)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try backing.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try backing.copyItem(at: srcURL, to: dstURL)
    }

    func copyItemWithProgress(
        at srcURL: URL,
        to dstURL: URL,
        onBytesCopied: @escaping @Sendable (Int64) async -> Void
    ) async throws {
        try await Task.sleep(for: .seconds(30))
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try backing.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(at URL: URL) throws {
        try backing.removeItem(at: URL)
    }

    func trashItem(
        at url: URL,
        resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try backing.trashItem(at: url, resultingItemURL: resultingItemURL)
    }

    func volumeIdentifier(for url: URL) throws -> String? {
        try backing.volumeIdentifier(for: url)
    }
}
