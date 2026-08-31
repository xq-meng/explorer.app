import AppKit
import ExplorerUI
import XCTest
@testable import ExplorerApp

@MainActor
final class ExplorerNativeWindowTabTests: XCTestCase {
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
}
