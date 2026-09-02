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

    func testFreshWindowsAndTabsStartWithOnePaneAfterASplitWindow() throws {
        let suiteName = "ExplorerFreshSinglePane-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ExplorerSettingsStore(defaults: defaults)
        settings.dualPaneEnabled = true

        let windowController = ExplorerWindowController(settings: settings)
        let tabController = ExplorerWindowController(
            initialState: ExplorerWindowState(
                location: .computer,
                viewMode: .details,
                sortDescriptor: .nameAscending
            ),
            settings: settings
        )
        windowController.showWindow(nil)
        tabController.showWindow(nil)
        defer {
            windowController.window?.close()
            tabController.window?.close()
        }

        let windowContent = try XCTUnwrap(
            windowController.window?.contentViewController as? ExplorerWindowContentViewController
        )
        let tabContent = try XCTUnwrap(
            tabController.window?.contentViewController as? ExplorerWindowContentViewController
        )
        XCTAssertFalse(windowController.isDualPaneEnabled)
        XCTAssertFalse(tabController.isDualPaneEnabled)
        XCTAssertEqual(windowContent.paneCount, 1)
        XCTAssertEqual(tabContent.paneCount, 1)
    }

    func testEveryNewSplitStartsWithEqualPaneWidths() throws {
        let suiteName = "ExplorerEqualSplit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = ExplorerWindowController(
            settings: ExplorerSettingsStore(defaults: defaults)
        )
        controller.showWindow(nil)
        defer { controller.window?.close() }

        controller.setDualPaneEnabled(true)
        controller.window?.layoutIfNeeded()
        let content = try XCTUnwrap(
            controller.window?.contentViewController as? ExplorerWindowContentViewController
        )
        let workspaceSplit = try XCTUnwrap(
            content.view.subviews.compactMap { $0 as? NSSplitView }.first
        )
        let paneSplit = try XCTUnwrap(
            workspaceSplit.arrangedSubviews.compactMap { $0 as? NSSplitView }.first
        )
        XCTAssertEqual(
            paneSplit.subviews[0].frame.width,
            paneSplit.subviews[1].frame.width,
            accuracy: 1
        )

        paneSplit.setPosition(paneSplit.bounds.width * 0.65, ofDividerAt: 0)
        XCTAssertGreaterThan(
            abs(paneSplit.subviews[0].frame.width - paneSplit.subviews[1].frame.width),
            10
        )
        controller.setDualPaneEnabled(false)
        controller.setDualPaneEnabled(true)
        controller.window?.layoutIfNeeded()

        XCTAssertEqual(
            paneSplit.subviews[0].frame.width,
            paneSplit.subviews[1].frame.width,
            accuracy: 1
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

    func testDualPaneUsesIndependentSessionsAndKeepsTheActivePaneWhenClosed() async throws {
        let suiteName = "ExplorerDualPane-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ExplorerSettingsStore(defaults: defaults)
        let controller = ExplorerWindowController(settings: settings)
        let content = try XCTUnwrap(
            controller.window?.contentViewController as? ExplorerWindowContentViewController
        )

        controller.showWindow(nil)
        defer { controller.window?.close() }
        controller.setDualPaneEnabled(true)

        XCTAssertTrue(controller.isDualPaneEnabled)
        XCTAssertTrue(settings.dualPaneEnabled)
        XCTAssertEqual(content.paneCount, 2)
        XCTAssertEqual(controller.activePaneIndex, 0)
        XCTAssertTrue(content.hasSharedSidebar)
        XCTAssertFalse(content.paneControllers[0].browser.isSidebarVisible)
        XCTAssertFalse(content.paneControllers[1].browser.isSidebarVisible)
        XCTAssertTrue(content.paneControllers[0].browser.isPaneActive)
        XCTAssertFalse(content.paneControllers[1].browser.isPaneActive)
        XCTAssertEqual(content.paneControllers[0].browser.view.layer?.borderWidth, 0)
        XCTAssertEqual(content.paneControllers[1].browser.view.layer?.borderWidth, 0)

        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        sendPrimaryClick(
            to: content.paneControllers[1].browser.view,
            at: NSPoint(
                x: content.paneControllers[1].browser.view.bounds.midX,
                y: content.paneControllers[1].browser.view.bounds.maxY - 12
            ),
            in: window
        )
        XCTAssertEqual(controller.activePaneIndex, 1)
        XCTAssertFalse(content.paneControllers[0].browser.isPaneActive)
        XCTAssertTrue(content.paneControllers[1].browser.isPaneActive)
        XCTAssertEqual(content.paneControllers[0].browser.view.layer?.borderWidth, 0)
        XCTAssertEqual(content.paneControllers[1].browser.view.layer?.borderWidth, 0)

        let sidebarDestination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerSidebarRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sidebarDestination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sidebarDestination) }
        content.onSidebarAction?(.openLocation(.directory(sidebarDestination)))
        for _ in 0..<200 where content.paneControllers[1].currentDirectoryURL != sidebarDestination {
            await Task.yield()
        }
        XCTAssertEqual(content.paneControllers[1].currentDirectoryURL, sidebarDestination)
        XCTAssertEqual(content.paneControllers[0].currentLocation, .computer)

        let splitButton = try XCTUnwrap(
            firstDescendant(
                of: content.paneControllers[1].browser.view,
                as: NSButton.self,
                identifier: "browser.dualPane"
            )
        )
        XCTAssertEqual(splitButton.toolTip, "Close Split View (Command-\\)")
        splitButton.performClick(nil)

        XCTAssertFalse(controller.isDualPaneEnabled)
        XCTAssertFalse(settings.dualPaneEnabled)
        XCTAssertEqual(content.paneCount, 1)
        XCTAssertEqual(controller.activePaneIndex, 0)
        XCTAssertTrue(content.hasSharedSidebar)
        XCTAssertFalse(content.paneControllers[0].browser.isSidebarVisible)
        XCTAssertEqual(content.paneControllers[0].currentDirectoryURL, sidebarDestination)
        let remainingButton = try XCTUnwrap(
            firstDescendant(
                of: content.paneControllers[0].browser.view,
                as: NSButton.self,
                identifier: "browser.dualPane"
            )
        )
        XCTAssertEqual(remainingButton.toolTip, "Show Split View (Command-\\)")
    }

    func testDualPaneRestoresIndependentPathsHistorySelectionViewAndScroll() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerDualPaneRestore-\(UUID().uuidString)", isDirectory: true)
        let left = root.appendingPathComponent("Left", isDirectory: true)
        let right = root.appendingPathComponent("Right", isDirectory: true)
        let history = root.appendingPathComponent("History", isDirectory: true)
        for directory in [left, right, history] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for index in 0..<80 {
            try Data("item \(index)".utf8).write(
                to: left.appendingPathComponent(String(format: "item-%03d.txt", index))
            )
            try Data("item \(index)".utf8).write(
                to: right.appendingPathComponent(String(format: "item-%03d.txt", index))
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let leftSelection = left.appendingPathComponent("item-022.txt")
        let rightSelection = right.appendingPathComponent("item-047.txt")
        let leftAnchor = left.appendingPathComponent("item-018.txt")
        let rightAnchor = right.appendingPathComponent("item-040.txt")
        let missingHistory = root.appendingPathComponent("Missing", isDirectory: true)
        let savedState = ExplorerDualPaneRestorationState(
            panes: [
                ExplorerPaneRestorationState(
                    location: .directory(left),
                    backHistory: [.computer, .directory(history), .directory(missingHistory)],
                    forwardHistory: [.directory(right)],
                    selection: [leftSelection],
                    viewMode: .details,
                    sortDescriptor: .nameAscending,
                    scrollPosition: BrowserScrollPosition(
                        anchorURL: leftAnchor,
                        horizontalOffset: 0,
                        verticalOffset: 0,
                        anchorVerticalOffset: 3
                    )
                ),
                ExplorerPaneRestorationState(
                    location: .directory(right),
                    backHistory: [.directory(left)],
                    forwardHistory: [.computer],
                    selection: [rightSelection],
                    viewMode: .icons,
                    sortDescriptor: BrowserSortDescriptor(field: .modified, ascending: false),
                    scrollPosition: BrowserScrollPosition(
                        anchorURL: rightAnchor,
                        horizontalOffset: 0,
                        verticalOffset: 0,
                        anchorVerticalOffset: 2
                    )
                ),
            ],
            activePaneIndex: 1
        )

        let suiteName = "ExplorerDualPaneRestoreSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ExplorerSettingsStore(defaults: defaults)
        settings.dualPaneEnabled = true
        settings.dualPaneRestorationState = savedState
        XCTAssertEqual(settings.dualPaneRestorationState, savedState)

        let controller = ExplorerWindowController(
            settings: settings,
            restoresSavedDualPaneSession: true
        )
        controller.showWindow(nil)
        defer { controller.window?.close() }
        let content = try XCTUnwrap(
            controller.window?.contentViewController as? ExplorerWindowContentViewController
        )

        for _ in 0..<500 {
            let panes = content.paneControllers
            if panes.count == 2,
               panes[0].currentDirectoryURL == left,
               panes[1].currentDirectoryURL == right,
               panes[0].selection.map(\.lastPathComponent) == [leftSelection.lastPathComponent],
               panes[1].selection.map(\.lastPathComponent) == [rightSelection.lastPathComponent],
               panes[0].restorationState()?.scrollPosition?.anchorURL == leftAnchor,
               panes[1].restorationState()?.scrollPosition?.verticalOffset ?? 0 > 0 {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(content.paneCount, 2)
        XCTAssertEqual(controller.activePaneIndex, 1)
        let leftState = try XCTUnwrap(content.paneControllers[0].restorationState())
        let rightState = try XCTUnwrap(content.paneControllers[1].restorationState())
        XCTAssertEqual(leftState.location, .directory(left))
        XCTAssertEqual(leftState.backHistory, [.computer, .directory(history)])
        XCTAssertEqual(leftState.forwardHistory, [.directory(right)])
        XCTAssertEqual(leftState.selection.map(\.lastPathComponent), [leftSelection.lastPathComponent])
        XCTAssertEqual(leftState.viewMode, .details)
        XCTAssertEqual(leftState.scrollPosition?.anchorURL, leftAnchor)
        XCTAssertEqual(rightState.location, .directory(right))
        XCTAssertEqual(rightState.backHistory, [.directory(left)])
        XCTAssertEqual(rightState.forwardHistory, [.computer])
        XCTAssertEqual(rightState.selection.map(\.lastPathComponent), [rightSelection.lastPathComponent])
        XCTAssertEqual(rightState.viewMode, .icons)
        XCTAssertEqual(
            rightState.sortDescriptor,
            BrowserSortDescriptor(field: .modified, ascending: false)
        )
        XCTAssertGreaterThan(rightState.scrollPosition?.verticalOffset ?? 0, 0)
    }

    func testDualPaneRestorationFallsBackWhenSavedDirectoryDisappeared() async throws {
        let suiteName = "ExplorerDualPaneMissingSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ExplorerSettingsStore(defaults: defaults)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerMissing-\(UUID().uuidString)", isDirectory: true)
        let pane = ExplorerPaneRestorationState(
            location: .directory(missing),
            backHistory: [.directory(missing)],
            forwardHistory: [],
            selection: [missing.appendingPathComponent("gone.txt")],
            viewMode: .details,
            sortDescriptor: .nameAscending,
            scrollPosition: BrowserScrollPosition(
                anchorURL: missing.appendingPathComponent("gone.txt"),
                horizontalOffset: 0,
                verticalOffset: 200,
                anchorVerticalOffset: 0
            )
        )
        settings.dualPaneEnabled = true
        settings.dualPaneRestorationState = ExplorerDualPaneRestorationState(
            panes: [pane, pane],
            activePaneIndex: 0
        )

        let controller = ExplorerWindowController(
            settings: settings,
            restoresSavedDualPaneSession: true
        )
        controller.showWindow(nil)
        defer { controller.window?.close() }
        let content = try XCTUnwrap(
            controller.window?.contentViewController as? ExplorerWindowContentViewController
        )

        for _ in 0..<200 where content.paneCount != 2 {
            await Task.yield()
        }

        XCTAssertEqual(content.paneControllers.map(\.currentLocation), [.computer, .computer])
        XCTAssertTrue(content.paneControllers.allSatisfy { $0.selection.isEmpty })
        XCTAssertTrue(content.paneControllers.allSatisfy {
            $0.restorationState()?.backHistory.isEmpty == true
                && $0.restorationState()?.scrollPosition == nil
        })
    }

    func testCopyToOtherPaneUsesTheActiveSelectionAndOtherDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerDualPaneCopy-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("Destination", isDirectory: true)
        let journalDirectory = root.appendingPathComponent("Journal", isDirectory: true)
        let source = sourceDirectory.appendingPathComponent("transfer.txt")
        let destination = destinationDirectory.appendingPathComponent("transfer.txt")
        let moveSource = sourceDirectory.appendingPathComponent("move.txt")
        let moveDestination = destinationDirectory.appendingPathComponent("move.txt")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try Data("dual pane".utf8).write(to: source)
        try Data("move across panes".utf8).write(to: moveSource)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "ExplorerDualPaneCopySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let queue = FileOperationQueue(
            engine: FileOperationEngine(
                recoveryJournal: FileOperationRecoveryJournal(directory: journalDirectory)
            )
        )
        let controller = ExplorerWindowController(
            operationQueue: queue,
            settings: ExplorerSettingsStore(defaults: defaults)
        )
        controller.setDualPaneEnabled(true)
        let content = try XCTUnwrap(
            controller.window?.contentViewController as? ExplorerWindowContentViewController
        )
        let panes = content.paneControllers
        XCTAssertEqual(panes.count, 2)
        panes[0].start(at: .directory(sourceDirectory))
        panes[1].start(at: .directory(destinationDirectory))

        for _ in 0..<200 {
            if panes[0].currentDirectoryURL == sourceDirectory,
               panes[1].currentDirectoryURL == destinationDirectory { break }
            await Task.yield()
        }
        panes[0].selection = [source]
        panes[0].pushViewState()
        XCTAssertTrue(controller.canTransferSelectionToOtherPane)

        controller.copySelectionToOtherPane()

        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: destination.path),
               !controller.hasActiveFileOperations { break }
            await Task.yield()
        }
        XCTAssertEqual(try String(contentsOf: destination), "dual pane")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        panes[0].selection = [moveSource]
        panes[0].pushViewState()
        controller.moveSelectionToOtherPane()
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: moveDestination.path),
               !controller.hasActiveFileOperations { break }
            await Task.yield()
        }
        XCTAssertEqual(try String(contentsOf: moveDestination), "move across panes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveSource.path))
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

@MainActor
private func sendPrimaryClick(to view: NSView, at point: NSPoint, in window: NSWindow) {
    let location = view.convert(point, to: nil)
    for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(
            with: eventType,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: eventType == .leftMouseDown ? 1 : 0
        ) else { continue }
        NSApp.sendEvent(event)
    }
}

@MainActor
private func firstDescendant<T: NSView>(
    of root: NSView,
    as type: T.Type,
    identifier: String
) -> T? {
    if let match = root as? T, match.identifier?.rawValue == identifier {
        return match
    }
    for subview in root.subviews {
        if let match = firstDescendant(of: subview, as: type, identifier: identifier) {
            return match
        }
    }
    return nil
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
