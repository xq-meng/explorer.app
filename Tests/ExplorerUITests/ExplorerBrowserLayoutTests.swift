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
        (table.delegate as? BrowserFileContentController)?
            .tableView(table, sortDescriptorsDidChange: previous)

        XCTAssertEqual(received, BrowserSortDescriptor(field: .size, ascending: false))
    }

    func testFileSelectionRoutesThroughBrowserAndSurvivesViewModeChange() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        controller.displayRows([
            BrowserFileRow(
                url: firstURL,
                name: "first.txt",
                modifiedDate: "Today",
                size: "1 KB",
                kind: "Text",
                isNavigable: false
            ),
            BrowserFileRow(
                url: secondURL,
                name: "second.txt",
                modifiedDate: "Today",
                size: "2 KB",
                kind: "Text",
                isNavigable: false
            ),
        ], selecting: [secondURL])

        guard let table = allDescendants(of: controller.view, as: NSTableView.self)
            .first(where: { !($0 is NSOutlineView) }),
              let collection = allDescendants(of: controller.view, as: NSCollectionView.self).first,
              let contentController = table.delegate as? BrowserFileContentController else {
            return XCTFail("Expected both folder content presentations")
        }
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(collection.selectionIndexes, IndexSet(integer: 1))

        var selectedURLs: Set<URL> = []
        controller.onSelectionChange = { selectedURLs = $0 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        contentController.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        )
        XCTAssertEqual(selectedURLs, [firstURL.standardizedFileURL])

        controller.setViewMode(.icons)
        XCTAssertEqual(collection.selectionIndexes, IndexSet(integer: 0))
    }

    func testConflictAlertUsesSafeDefaultAndApplyToAll() {
        let prompt = BrowserConflictPrompt(
            sourceName: "report.txt",
            destinationName: "report.txt",
            destinationFolder: "Documents",
            operationTitle: "Copy",
            remainingItemCount: 4
        )
        let (alert, applyToAll) = BrowserConflictAlert.makeAlert(prompt: prompt)
        XCTAssertEqual(alert.buttons.map(\.title), ["Keep Both", "Skip", "Replace", "Stop"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[3].keyEquivalent, "\u{1b}")
        XCTAssertIdentical(alert.accessoryView, applyToAll)

        let keepBoth = BrowserConflictAlert.decision(from: .alertFirstButtonReturn, applyToAll: true)
        XCTAssertEqual(keepBoth, BrowserConflictDecision(choice: .keepBoth, applyToAll: true))
        let stop = BrowserConflictAlert.decision(
            from: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1),
            applyToAll: true
        )
        XCTAssertEqual(stop.choice, BrowserConflictChoice.stop)
        XCTAssertFalse(stop.applyToAll)
    }

    func testConflictAlertHidesApplyToAllForTheLastItem() {
        let prompt = BrowserConflictPrompt(
            sourceName: "report.txt",
            destinationName: "report.txt",
            destinationFolder: "Documents",
            operationTitle: "Move",
            remainingItemCount: 0
        )
        let (alert, _) = BrowserConflictAlert.makeAlert(prompt: prompt)
        XCTAssertNil(alert.accessoryView)
    }

    func testSearchFieldIsLabeledForSubtreeSearch() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        guard let field = allDescendants(of: controller.view, as: NSSearchField.self).first else {
            return XCTFail("Expected the folder search field")
        }
        XCTAssertEqual(field.placeholderString, "Search")
        XCTAssertEqual(field.accessibilityLabel(), "Search this folder")
    }

    func testFolderViewsRegisterPromisedFileDropTypes() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        let promised = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        XCTAssertFalse(promised.isEmpty)

        guard let table = allDescendants(of: controller.view, as: NSTableView.self)
            .first(where: { !($0 is NSOutlineView) }) else {
            return XCTFail("Expected the folder contents table")
        }
        XCTAssertTrue(promised.isSubset(of: Set(table.registeredDraggedTypes)))
        XCTAssertTrue(table.registeredDraggedTypes.contains(.fileURL))

        guard let collection = allDescendants(of: controller.view, as: NSCollectionView.self).first else {
            return XCTFail("Expected the icon collection")
        }
        XCTAssertTrue(promised.isSubset(of: Set(collection.registeredDraggedTypes)))
    }

    func testDropPasteboardPrefersFileURLsOverPromises() {
        let url = URL(fileURLWithPath: "/tmp/explorer-drop-test.txt")
        let reader = BrowserDropPasteboardReaderStub(
            fileURLs: [url],
            hasPromisedFiles: true
        )

        XCTAssertTrue(BrowserDropPasteboard.canAccept(reader))
        XCTAssertTrue(BrowserDropPasteboard.containsFileURLs(reader))
        XCTAssertTrue(BrowserDropPasteboard.containsPromisedFiles(reader))
        let payload = BrowserDropPasteboard.read(reader)
        XCTAssertEqual(payload.fileURLs.map(\.path), [url.standardizedFileURL.path])
        XCTAssertTrue(payload.promisedFileReceivers.isEmpty)
        XCTAssertFalse(reader.didReadPromisedFileReceivers)
        XCTAssertTrue(BrowserDropPasteboard.draggedTypes.contains(.fileURL))
        XCTAssertFalse(BrowserDropPasteboard.promisedFileTypes.isEmpty)
    }

    func testOperationActivityViewShowsProgressAndCancel() {
        let view = BrowserOperationActivityView(frame: NSRect(x: 0, y: 0, width: 640, height: 56))
        view.display(BrowserOperationActivity(
            title: "Copying 1 of 3",
            detail: "report.txt — 12 MB of 40 MB",
            fractionCompleted: 0.3,
            queuedCount: 1
        ))
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.accessibilityLabel(), "Copying 1 of 3")

        var cancelled = false
        view.onCancel = { cancelled = true }
        view.display(nil)
        XCTAssertTrue(view.isHidden)

        view.display(BrowserOperationActivity(title: "Moving 1 of 1", detail: "Notes", fractionCompleted: 0.8))
        let button = allDescendants(of: view, as: NSButton.self).first { $0.title == "Cancel" }
        XCTAssertNotNil(button)
        button?.performClick(nil)
        XCTAssertTrue(cancelled)
    }
}

private final class BrowserDropPasteboardReaderStub: BrowserDropPasteboardReading {
    let fileURLs: [URL]
    let hasPromisedFiles: Bool
    private(set) var didReadPromisedFileReceivers = false

    var hasFileURLs: Bool { !fileURLs.isEmpty }

    init(fileURLs: [URL], hasPromisedFiles: Bool) {
        self.fileURLs = fileURLs
        self.hasPromisedFiles = hasPromisedFiles
    }

    func readFileURLs() -> [URL] {
        fileURLs
    }

    func readPromisedFileReceivers() -> [NSFilePromiseReceiver] {
        didReadPromisedFileReceivers = true
        return []
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
