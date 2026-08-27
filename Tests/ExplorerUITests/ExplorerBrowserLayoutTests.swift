import AppKit
import XCTest
@testable import ExplorerUI

@MainActor
final class ExplorerBrowserLayoutTests: XCTestCase {
    func testBrowserContentFillsAWindowSizedRootView() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_080, height: 680)
        controller.view.layoutSubtreeIfNeeded()

        let splitView = controller.view.subviews.compactMap { $0 as? NSSplitView }.first
        XCTAssertNotNil(splitView)
        XCTAssertEqual(splitView?.frame.size.width ?? 0, 1_080, accuracy: 1)
        XCTAssertEqual(splitView?.frame.size.height ?? 0, 680, accuracy: 1)
        XCTAssertEqual(splitView?.arrangedSubviews.count, 2)
        XCTAssertGreaterThan(splitView?.arrangedSubviews.last?.frame.width ?? 0, 0)
        XCTAssertNotNil(firstDescendant(of: controller.view, as: NSOutlineView.self))
        XCTAssertGreaterThanOrEqual(allDescendants(of: controller.view, as: NSSplitView.self).count, 2)
    }

    func testSidebarRequestsAndAppliesChildrenLazily() {
        let controller = BrowserSidebarController()
        let rootURL = URL(fileURLWithPath: "/tmp/sidebar-root", isDirectory: true)
        let childURL = rootURL.appendingPathComponent("Child", isDirectory: true)
        controller.displayRoots([BrowserSidebarLocation(title: "Root", url: rootURL, kind: .favorite)])

        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        guard let root = controller.outlineView.item(atRow: 1) else {
            return XCTFail("Expected a visible root node")
        }

        var requestedURL: URL?
        controller.onExpansionRequest = { requestedURL = $0 }
        XCTAssertTrue(controller.outlineView(controller.outlineView, shouldExpandItem: root))
        XCTAssertEqual(requestedURL, rootURL.standardizedFileURL)

        controller.displayChildren(
            [BrowserSidebarLocation(title: "Child", url: childURL)],
            for: rootURL
        )
        XCTAssertEqual(controller.outlineView(controller.outlineView, numberOfChildrenOfItem: root), 1)
        XCTAssertGreaterThanOrEqual(controller.outlineView.numberOfRows, 2)
    }

    func testRightPaneNavigationDoesNotChangeSidebarSelection() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.displaySidebarLocations([
            BrowserSidebarLocation(
                title: "Home",
                url: URL(fileURLWithPath: "/tmp/sidebar-home", isDirectory: true),
                kind: .favorite
            ),
        ])
        guard let outlineView = firstDescendant(of: controller.view, as: NSOutlineView.self) else {
            return XCTFail("Expected the Favorites tree")
        }
        outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        controller.displayPath("/tmp/an-independent-location")

        XCTAssertEqual(outlineView.selectedRow, 1)
    }

    func testSidebarDividerCanBeAdjustedAfterInitialLayout() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_080, height: 680)
        controller.view.layoutSubtreeIfNeeded()
        guard let splitView = controller.view.subviews.compactMap({ $0 as? NSSplitView }).first else {
            return XCTFail("Expected the browser split view")
        }

        controller.setSidebarWidth(196)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(splitView.subviews[0].frame.width, 196, accuracy: 1)

        splitView.setPosition(244, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(splitView.subviews[0].frame.width, 244, accuracy: 1)
    }

    func testHidingPreviewRemovesItsSplitDivider() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        let splitViews = allDescendants(of: controller.view, as: NSSplitView.self)
        guard let previewSplitView = splitViews.dropFirst().first else {
            return XCTFail("Expected the preview split view")
        }
        XCTAssertEqual(previewSplitView.arrangedSubviews.count, 2)

        controller.setPreviewVisible(false)
        XCTAssertEqual(previewSplitView.arrangedSubviews.count, 1)

        controller.setPreviewVisible(true)
        XCTAssertEqual(previewSplitView.arrangedSubviews.count, 2)
    }

    func testTableSortDescriptorRoutesAStableBrowserSortIntent() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        guard let table = allDescendants(of: controller.view, as: NSTableView.self)
            .first(where: { !($0 is NSOutlineView) }) else {
            return XCTFail("Expected the folder contents table")
        }

        var received: BrowserSortDescriptor?
        controller.onSortSelection = { received = $0 }
        let previous = table.sortDescriptors
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        controller.tableView(table, sortDescriptorsDidChange: previous)

        XCTAssertEqual(received, BrowserSortDescriptor(field: .size, ascending: false))
    }
}

@MainActor
private func firstDescendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
    if let match = root as? T { return match }
    for child in root.subviews {
        if let match = firstDescendant(of: child, as: type) { return match }
    }
    return nil
}

@MainActor
private func allDescendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    var matches = root.subviews.compactMap { $0 as? T }
    for child in root.subviews { matches.append(contentsOf: allDescendants(of: child, as: type)) }
    return matches
}
