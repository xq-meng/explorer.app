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

    func testSidebarItemsOpenLocationsInsteadOfExpanding() {
        let controller = BrowserSidebarController()
        let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let volume = URL(fileURLWithPath: "/", isDirectory: true)
        let iCloud = URL(
            fileURLWithPath: "/tmp/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        controller.displayRoots([
            BrowserSidebarLocation(title: "Downloads", url: downloads, kind: .favorite),
            BrowserSidebarLocation(title: "Macintosh HD", url: volume, kind: .volume),
            BrowserSidebarLocation(title: "iCloud Drive", url: iCloud, kind: .network),
        ])

        XCTAssertEqual(controller.outlineView.numberOfRows, 6)
        let outline = controller.outlineView
        XCTAssertTrue(controller.outlineView(outline, isItemExpandable: outline.item(atRow: 0)!))
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: outline.item(atRow: 1)!))
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: outline.item(atRow: 3)!))
        XCTAssertFalse(controller.outlineView(outline, isItemExpandable: outline.item(atRow: 5)!))

        var opened: BrowserLocation?
        controller.onAction = { action in
            if case let .openLocation(location) = action {
                opened = location
            }
        }
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        if let action = outline.action {
            _ = (outline.target as AnyObject?)?.perform(action, with: outline)
        }
        XCTAssertEqual(opened, .directory(downloads.standardizedFileURL))
    }

    func testSidebarPlacesNetworkSectionAfterVolumes() {
        let controller = BrowserSidebarController()
        let home = URL(fileURLWithPath: "/tmp/sidebar-home", isDirectory: true)
        let volume = URL(fileURLWithPath: "/", isDirectory: true)
        let iCloud = URL(
            fileURLWithPath: "/tmp/sidebar-home/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        controller.displayRoots([
            BrowserSidebarLocation(title: "Home", url: home, kind: .favorite),
            BrowserSidebarLocation(title: "Macintosh HD", url: volume, kind: .volume),
            BrowserSidebarLocation(title: "iCloud Drive", url: iCloud, kind: .network),
        ])

        XCTAssertEqual(controller.outlineView.numberOfRows, 6)
        let titles = (0..<6).compactMap { row -> String? in
            guard let item = controller.outlineView.item(atRow: row) else { return nil }
            let cell = controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.tableColumns[0],
                item: item
            ) as? NSTableCellView
            return cell?.textField?.stringValue
        }
        XCTAssertEqual(titles, [
            "Favorites", "Home",
            "Volumes", "Macintosh HD",
            "Network", "iCloud Drive",
        ])
    }

    func testSidebarPlacesMyComputerFirstInFavorites() {
        let controller = BrowserSidebarController()
        let home = URL(fileURLWithPath: "/tmp/sidebar-home", isDirectory: true)
        controller.displayRoots([
            BrowserSidebarLocation(
                title: BrowserLocation.computerTitle,
                location: .computer,
                kind: .computer
            ),
            BrowserSidebarLocation(title: "Home", url: home, kind: .favorite),
        ])

        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        let computer = controller.outlineView.item(atRow: 1)
        XCTAssertNotNil(computer)
        XCTAssertFalse(
            controller.outlineView(controller.outlineView, isItemExpandable: computer!)
        )
        let titles = (0..<3).compactMap { row -> String? in
            guard let item = controller.outlineView.item(atRow: row) else { return nil }
            let cell = controller.outlineView(
                controller.outlineView,
                viewFor: controller.outlineView.tableColumns[0],
                item: item
            ) as? NSTableCellView
            return cell?.textField?.stringValue
        }
        XCTAssertEqual(titles, ["Favorites", "My Computer", "Home"])
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

        controller.displayLocation(.directory(URL(fileURLWithPath: "/tmp/an-independent-location")))

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

    func testBrowserChromeEmitsASingleActionStream() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_080, height: 680)
        controller.view.layoutSubtreeIfNeeded()

        var actions: [String] = []
        controller.onAction = { action in
            switch action {
            case .navigation(.back): actions.append("back")
            case .setViewMode(.icons): actions.append("icons")
            case .openLocation(.computer): actions.append("computer")
            default: break
            }
            return true
        }

        let back = allDescendants(of: controller.view, as: NSButton.self)
            .first { $0.accessibilityLabel() == "Back" }
        back?.performClick(nil)
        let viewMode = allDescendants(of: controller.view, as: NSSegmentedControl.self)
            .first { $0.identifier?.rawValue == "browser.viewMode" }
        viewMode?.selectedSegment = 1
        viewMode?.performClick(nil)

        XCTAssertEqual(actions, ["back", "icons"])
    }

    func testTableSortDescriptorRoutesAStableBrowserSortIntent() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        guard let table = allDescendants(of: controller.view, as: NSTableView.self)
            .first(where: { !($0 is NSOutlineView) }) else {
            return XCTFail("Expected the folder contents table")
        }

        var received: BrowserSortDescriptor?
        controller.onAction = { action in
            if case let .setSort(descriptor) = action {
                received = descriptor
            }
            return true
        }
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
        controller.onAction = { action in
            if case let .selectionChange(urls) = action {
                selectedURLs = urls
            }
            return true
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        contentController.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        )
        XCTAssertEqual(selectedURLs, [firstURL.standardizedFileURL])

        controller.setViewMode(.icons)
        XCTAssertEqual(collection.selectionIndexes, IndexSet(integer: 0))
    }

    func testFolderItemHoverPresentationPreservesSelectionAndDropPriority() {
        let rowView = BrowserFileTableRowView()
        rowView.setHovered(true)
        XCTAssertEqual(rowView.visualState, .hovered)
        rowView.isSelected = true
        XCTAssertEqual(rowView.visualState, .selected)
        rowView.isTargetForDropOperation = true
        XCTAssertEqual(rowView.visualState, .dropTarget)
        rowView.resetHover()
        XCTAssertFalse(rowView.isHovered)

        let iconItem = BrowserIconCollectionItem()
        iconItem.loadView()
        guard let iconView = iconItem.view as? BrowserIconItemView else {
            return XCTFail("Expected a hover-aware icon item view")
        }
        iconView.setHovered(true)
        XCTAssertEqual(iconView.visualState, .hovered)
        iconItem.isSelected = true
        XCTAssertEqual(iconView.visualState, .selected)
        iconItem.highlightState = .asDropTarget
        XCTAssertEqual(iconView.visualState, .dropTarget)
        iconItem.prepareForReuse()
        XCTAssertEqual(iconView.visualState, .normal)
    }

    func testSidebarItemRowsUseHoverPresentation() {
        let controller = BrowserSidebarController()
        let home = URL(fileURLWithPath: "/tmp/sidebar-home", isDirectory: true)
        controller.displayRoots([
            BrowserSidebarLocation(title: "Home", url: home, kind: .favorite),
        ])
        let outline = controller.outlineView
        guard let group = outline.item(atRow: 0),
              let node = outline.item(atRow: 1) else {
            return XCTFail("Expected a sidebar group and item")
        }

        let itemRow = controller.outlineView(outline, rowViewForItem: node)
        guard let hoverRow = itemRow as? BrowserFileTableRowView else {
            return XCTFail("Expected a hover-aware sidebar row")
        }
        hoverRow.setHovered(true)
        XCTAssertEqual(hoverRow.visualState, .hovered)
        hoverRow.isSelected = true
        XCTAssertEqual(hoverRow.visualState, .selected)
        hoverRow.resetHover()
        XCTAssertFalse(hoverRow.isHovered)

        let groupRow = controller.outlineView(outline, rowViewForItem: group) as? BrowserFileTableRowView
        groupRow?.isGroupRowStyle = true
        groupRow?.setHovered(true)
        XCTAssertEqual(groupRow?.visualState, .normal)
        XCTAssertEqual(groupRow?.isHovered, false)
    }

    func testHiddenAndCutItemsUseDimmedContentWithoutDimmingInteractionFeedback() {
        let hiddenURL = URL(fileURLWithPath: "/tmp/.hidden.txt")
        let visibleURL = URL(fileURLWithPath: "/tmp/visible.txt")
        let hiddenRow = BrowserFileRow(
            url: hiddenURL,
            name: ".hidden.txt",
            modifiedDate: "Today",
            size: "1 KB",
            kind: "Text",
            isNavigable: false,
            isHidden: true
        )
        let visibleRow = BrowserFileRow(
            url: visibleURL,
            name: "visible.txt",
            modifiedDate: "Today",
            size: "1 KB",
            kind: "Text",
            isNavigable: false
        )

        let iconItem = BrowserIconCollectionItem()
        iconItem.loadView()
        iconItem.display(hiddenRow)
        XCTAssertTrue(iconItem.view.subviews.allSatisfy {
            $0.alphaValue == BrowserItemPresentation.dimmedAlpha
        })
        iconItem.display(visibleRow, isCut: true)
        XCTAssertTrue(iconItem.view.subviews.allSatisfy {
            $0.alphaValue == BrowserItemPresentation.dimmedAlpha
        })
        XCTAssertEqual((iconItem.view as? BrowserIconItemView)?.visualState, .normal)

        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.displayRows([hiddenRow, visibleRow])
        guard let table = allDescendants(of: controller.view, as: NSTableView.self)
            .first(where: { !($0 is NSOutlineView) }) else {
            return XCTFail("Expected the folder contents table")
        }
        let hiddenCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(hiddenCell?.textField?.alphaValue, BrowserItemPresentation.dimmedAlpha)

        controller.setCutURLs([visibleURL])
        let cutCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(cutCell?.textField?.alphaValue, BrowserItemPresentation.dimmedAlpha)
        controller.setCutURLs([])
        let restoredCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(restoredCell?.textField?.alphaValue, 1)
    }

    func testNameColumnShowsCloudBadgeForCloudOnlyItems() {
        let cloudRow = BrowserFileRow(
            url: URL(fileURLWithPath: "/tmp/icloud/report.txt"),
            name: "report.txt",
            modifiedDate: "Today",
            size: "1 KB",
            kind: "Text",
            isNavigable: false,
            isCloudOnly: true
        )
        let localRow = BrowserFileRow(
            url: URL(fileURLWithPath: "/tmp/icloud/notes.txt"),
            name: "notes.txt",
            modifiedDate: "Today",
            size: "1 KB",
            kind: "Text",
            isNavigable: false
        )

        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.displayRows([cloudRow, localRow])
        guard let table = allDescendants(of: controller.view, as: NSTableView.self)
            .first(where: { !($0 is NSOutlineView) }) else {
            return XCTFail("Expected the folder contents table")
        }

        let cloudCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? BrowserFileNameCellView
        let localCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? BrowserFileNameCellView
        XCTAssertEqual(cloudCell?.cloudBadgeView.isHidden, false)
        XCTAssertEqual(localCell?.cloudBadgeView.isHidden, true)
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

    func testPermanentDeleteAlertUsesCancelAsTheReturnDefault() {
        let alert = BrowserPermanentDeleteAlert.makeAlert(itemCount: 1, itemName: "report.txt")
        XCTAssertEqual(alert.messageText, "Permanently delete “report.txt”?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Delete"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertTrue(alert.buttons[1].hasDestructiveAction)
        XCTAssertEqual(alert.window.defaultButtonCell, alert.buttons[0].cell)
        XCTAssertEqual(alert.alertStyle, .critical)

        let many = BrowserPermanentDeleteAlert.makeAlert(itemCount: 3, itemName: nil)
        XCTAssertEqual(many.messageText, "Permanently delete 3 items?")
    }

    func testPermanentDeleteAlertTabAndArrowsSwitchCancelAndDelete() {
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .cancel,
                charactersIgnoringModifiers: "\t",
                specialKey: nil,
                keyCode: 48,
                modifiers: []
            ),
            .delete
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .delete,
                charactersIgnoringModifiers: "\t",
                specialKey: nil,
                keyCode: 48,
                modifiers: []
            ),
            .cancel
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .cancel,
                charactersIgnoringModifiers: "\t",
                specialKey: nil,
                keyCode: 48,
                modifiers: .shift
            ),
            .delete
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .cancel,
                charactersIgnoringModifiers: nil,
                specialKey: .leftArrow,
                keyCode: 123,
                modifiers: []
            ),
            .cancel
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .cancel,
                charactersIgnoringModifiers: nil,
                specialKey: .rightArrow,
                keyCode: 124,
                modifiers: []
            ),
            .delete
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .delete,
                charactersIgnoringModifiers: nil,
                specialKey: .leftArrow,
                keyCode: 123,
                modifiers: []
            ),
            .cancel
        )
        XCTAssertNil(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .cancel,
                charactersIgnoringModifiers: "\r",
                specialKey: .carriageReturn,
                keyCode: 36,
                modifiers: []
            )
        )
        XCTAssertNil(
            BrowserPermanentDeleteAlert.nextFocus(
                current: .cancel,
                charactersIgnoringModifiers: "\t",
                specialKey: nil,
                keyCode: 48,
                modifiers: .command
            )
        )

        let alert = BrowserPermanentDeleteAlert.makeAlert(itemCount: 1, itemName: "report.txt")
        BrowserPermanentDeleteAlert.applyFocus(.delete, to: alert)
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.window.defaultButtonCell, alert.buttons[1].cell)
        BrowserPermanentDeleteAlert.applyFocus(.cancel, to: alert)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertEqual(alert.window.defaultButtonCell, alert.buttons[0].cell)
    }

    func testPermanentDeleteAlertReturnConfirmsFocusedButtonAndEscapeCancels() {
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.activation(
                charactersIgnoringModifiers: "\r",
                specialKey: .carriageReturn,
                keyCode: 36,
                modifiers: []
            ),
            .confirm
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.activation(
                charactersIgnoringModifiers: "\u{3}",
                specialKey: .enter,
                keyCode: 76,
                modifiers: []
            ),
            .confirm
        )
        XCTAssertEqual(
            BrowserPermanentDeleteAlert.activation(
                charactersIgnoringModifiers: "\u{1b}",
                specialKey: nil,
                keyCode: 53,
                modifiers: []
            ),
            .cancel
        )
        XCTAssertNil(
            BrowserPermanentDeleteAlert.activation(
                charactersIgnoringModifiers: "\t",
                specialKey: nil,
                keyCode: 48,
                modifiers: []
            )
        )
    }

    func testPermanentDeleteAlertHandlesKeyEventsFromTheSheetParentWindow() {
        let alertWindow = NSObject()
        let parentWindow = NSObject()
        let otherWindow = NSObject()
        let alertID = ObjectIdentifier(alertWindow)
        let parentID = ObjectIdentifier(parentWindow)
        let otherID = ObjectIdentifier(otherWindow)
        XCTAssertTrue(
            BrowserPermanentDeleteAlert.shouldHandleEvent(
                eventWindowID: parentID,
                alertWindowID: alertID,
                sheetParentID: parentID
            )
        )
        XCTAssertTrue(
            BrowserPermanentDeleteAlert.shouldHandleEvent(
                eventWindowID: alertID,
                alertWindowID: alertID,
                sheetParentID: parentID
            )
        )
        XCTAssertFalse(
            BrowserPermanentDeleteAlert.shouldHandleEvent(
                eventWindowID: otherID,
                alertWindowID: alertID,
                sheetParentID: parentID
            )
        )
        XCTAssertFalse(
            BrowserPermanentDeleteAlert.shouldHandleEvent(
                eventWindowID: parentID,
                alertWindowID: alertID,
                sheetParentID: nil
            )
        )
    }

    func testBackspaceNavigatesBackAndForwardDeleteRemovesItems() {
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{7F}",
                specialKey: .delete,
                modifiers: []
            ),
            .navigation(.back)
        )
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{8}",
                specialKey: nil,
                modifiers: []
            ),
            .navigation(.back)
        )
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{F728}",
                specialKey: .deleteForward,
                modifiers: []
            ),
            .file(.moveToTrash)
        )
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{F728}",
                specialKey: .deleteForward,
                modifiers: .shift
            ),
            .file(.deletePermanently)
        )
        XCTAssertNil(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{7F}",
                specialKey: .delete,
                modifiers: .shift
            )
        )
        XCTAssertNil(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{F728}",
                specialKey: .deleteForward,
                modifiers: .command
            )
        )
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: " ",
                specialKey: nil,
                modifiers: []
            ),
            .file(.quickLook)
        )
        XCTAssertNil(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: " ",
                specialKey: nil,
                modifiers: .shift
            )
        )

        let table = BrowserFileTableView()
        var tableCommand: BrowserKeyboardCommand?
        table.onKeyboardCommand = { tableCommand = $0 }
        if let backspaceEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{8}",
            charactersIgnoringModifiers: "\u{8}",
            isARepeat: false,
            keyCode: 51
        ) {
            table.keyDown(with: backspaceEvent)
        }
        XCTAssertEqual(tableCommand, .navigation(.back))

        let collection = BrowserDropCollectionView()
        var collectionCommand: BrowserKeyboardCommand?
        collection.onKeyboardCommand = { collectionCommand = $0 }
        if let deleteEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .shift,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{F728}",
            charactersIgnoringModifiers: "\u{F728}",
            isARepeat: false,
            keyCode: 117
        ) {
            collection.keyDown(with: deleteEvent)
        }
        XCTAssertEqual(collectionCommand, .file(.deletePermanently))
    }

    func testBreadcrumbBarLeavesPathEditingWhenEditingEnds() {
        let bar = BrowserBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        bar.display(URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true))
        bar.focusAddressField()
        XCTAssertTrue(bar.isEditingPath)
        bar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: nil))
        XCTAssertFalse(bar.isEditingPath)
    }

    func testToolbarButtonsShowHoverFeedbackOnlyWhileEnabled() {
        let button = BrowserToolbarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertFalse(button.showsHoverHighlight)

        button.setHovered(true)
        XCTAssertTrue(button.showsHoverHighlight)

        button.isEnabled = false
        XCTAssertFalse(button.showsHoverHighlight)

        button.isEnabled = true
        button.setHovered(false)
        XCTAssertFalse(button.showsHoverHighlight)
    }

    func testNavigationAndBreadcrumbActionsUseHoverButtons() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        let navigationButtons = allDescendants(of: controller.view, as: BrowserToolbarButton.self)
            .filter { ["Back", "Forward", "Up"].contains($0.toolTip ?? "") }
        XCTAssertEqual(navigationButtons.count, 3)

        let bar = BrowserBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        bar.display(URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true))
        let breadcrumbButtons = allDescendants(of: bar, as: BrowserToolbarButton.self)
        XCTAssertGreaterThanOrEqual(breadcrumbButtons.count, 5)
        XCTAssertTrue(breadcrumbButtons.contains { $0.toolTip == "Edit path (Command-L)" })
    }

    func testBreadcrumbBarEntersPathEditingWhenEmptyScrollAreaIsClicked() {
        let bar = BrowserBreadcrumbBar()
        let window = makeBreadcrumbTestWindow(hosting: bar)
        defer { window.orderOut(nil) }

        guard let pathScrollView = allDescendants(of: bar, as: NSScrollView.self).first else {
            return XCTFail("Expected the breadcrumb scroll view")
        }
        let localPoint = NSPoint(x: pathScrollView.bounds.maxX - 8, y: pathScrollView.bounds.midY)
        sendPrimaryClick(to: pathScrollView, at: localPoint, in: window)

        XCTAssertTrue(bar.isEditingPath)
    }

    func testBreadcrumbBarEditsOnCurrentComponentAndNavigatesOnParents() {
        let bar = BrowserBreadcrumbBar()
        bar.display(URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true))
        let window = makeBreadcrumbTestWindow(hosting: bar)
        defer { window.orderOut(nil) }
        let pathButtons = allDescendants(of: bar, as: NSButton.self).filter { !$0.title.isEmpty }
        guard let parentButton = pathButtons.first(where: { $0.title == "demo" }),
              let currentButton = pathButtons.first(where: { $0.title == "Documents" }) else {
            return XCTFail("Expected parent and current breadcrumb buttons")
        }

        var navigated: BrowserLocation?
        bar.onNavigate = { navigated = $0 }

        sendPrimaryClick(to: parentButton, at: parentButton.bounds.center, in: window)
        XCTAssertEqual(
            navigated,
            .directory(URL(fileURLWithPath: "/Users/demo", isDirectory: true))
        )
        XCTAssertFalse(bar.isEditingPath)

        navigated = nil
        sendPrimaryClick(to: currentButton, at: currentButton.bounds.center, in: window)
        XCTAssertNil(navigated)
        XCTAssertTrue(bar.isEditingPath)
    }

    func testBreadcrumbBarShowsICloudDriveTrail() {
        let bar = BrowserBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        let cloudDocs = URL(
            fileURLWithPath: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        let stash = URL(
            fileURLWithPath: "/Users/demo/Library/Mobile Documents/iCloud~ws~stash~icloud/Documents",
            isDirectory: true
        )
        bar.display(
            .directory(stash),
            trail: [
                BrowserPathComponent(title: "iCloud Drive", location: .directory(cloudDocs)),
                BrowserPathComponent(title: "stash", location: .directory(stash)),
            ]
        )
        let titles = allDescendants(of: bar, as: NSButton.self).map(\.title)
        XCTAssertEqual(titles.filter { $0 == "iCloud Drive" || $0 == "stash" }, ["iCloud Drive", "stash"])
        XCTAssertFalse(titles.contains("Mobile Documents"))
    }

    func testBreadcrumbBarShowsMyComputerForTheHomePage() {
        let bar = BrowserBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        bar.display(.computer)
        let titles = allDescendants(of: bar, as: NSButton.self).map(\.title)
        XCTAssertEqual(
            titles.filter { $0 == BrowserLocation.computerTitle },
            [BrowserLocation.computerTitle]
        )
        XCTAssertFalse(titles.contains("/"))
    }

    func testHomePageShowsFavoritesAndVolumeCapacity() {
        let controller = ExplorerBrowserViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_080, height: 680)
        let documents = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let downloads = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let desktop = URL(fileURLWithPath: "/tmp/Desktop", isDirectory: true)
        let volume = URL(fileURLWithPath: "/", isDirectory: true)
        let iCloud = URL(
            fileURLWithPath: "/tmp/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        controller.displayHomePage(
            BrowserHomePageModel(
                favorites: [
                    BrowserHomePageItem(title: "Documents", url: documents, subtitle: documents.path),
                    BrowserHomePageItem(title: "Downloads", url: downloads, subtitle: downloads.path),
                    BrowserHomePageItem(title: "Desktop", url: desktop, subtitle: desktop.path),
                ],
                volumes: [
                    BrowserHomePageVolume(
                        title: "Macintosh HD",
                        url: volume,
                        availableCapacity: 128_000_000_000,
                        totalCapacity: 512_000_000_000
                    ),
                ],
                network: [
                    BrowserHomePageItem(title: "iCloud Drive", url: iCloud, subtitle: iCloud.path),
                ]
            )
        )
        controller.view.layoutSubtreeIfNeeded()

        let labels = allDescendants(of: controller.view, as: NSTextField.self).map(\.stringValue)
        XCTAssertTrue(labels.contains("My Computer"))
        XCTAssertTrue(labels.contains("Documents"))
        XCTAssertTrue(labels.contains("Downloads"))
        XCTAssertTrue(labels.contains("Desktop"))
        XCTAssertTrue(labels.contains("Macintosh HD"))
        XCTAssertTrue(labels.contains("iCloud Drive"))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("Favorites (") }))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("Devices and Drives (") }))
        XCTAssertTrue(labels.contains(where: { $0.hasPrefix("Network Locations (") }))
        XCTAssertTrue(labels.contains(where: { $0.contains("free of") }))

        let home = allDescendants(of: controller.view, as: NSView.self)
            .first { $0.identifier?.rawValue == "home.page" }
        XCTAssertEqual(home?.isHidden, false)
        XCTAssertFalse(
            allDescendants(of: controller.view, as: NSView.self)
                .filter { $0.identifier?.rawValue == "home.item" }
                .isEmpty
        )
        let viewModeControl = allDescendants(of: controller.view, as: NSSegmentedControl.self)
            .first { $0.identifier?.rawValue == "browser.viewMode" }
        XCTAssertEqual(viewModeControl?.isHidden, true)

        let favoriteTiles = allDescendants(of: controller.view, as: BrowserHomeItemView.self)
            .filter { $0.identifier?.rawValue == "home.item" }
        XCTAssertGreaterThanOrEqual(favoriteTiles.count, 3)

        let first = favoriteTiles[0]
        let second = favoriteTiles[1]
        let third = favoriteTiles[2]
        XCTAssertGreaterThan(second.frame.minX, first.frame.maxX - 1)
        XCTAssertGreaterThan(third.frame.minX, second.frame.maxX - 1)
        XCTAssertGreaterThan(first.frame.width, 40)
        XCTAssertGreaterThan(second.frame.width, 40)

        if let home {
            for tile in [first, second, third] {
                let point = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: home)
                XCTAssertIdentical(home.hitTest(point), tile, "Tile \(tile.accessibilityLabel() ?? "") should receive clicks")
            }
        }

        var opened: URL?
        controller.onAction = { action in
            if case let .openLocation(.directory(url)) = action {
                opened = url
            }
            return true
        }
        second.mouseDown(with: mouseDownEvent(clickCount: 1))
        XCTAssertNil(opened)
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        second.mouseDown(with: mouseDownEvent(clickCount: 2))
        let openedAfterDoubleClick = expectation(description: "double-click opens")
        DispatchQueue.main.async { openedAfterDoubleClick.fulfill() }
        wait(for: [openedAfterDoubleClick], timeout: 1)
        XCTAssertEqual(opened, downloads.standardizedFileURL)
        opened = nil
        third.performOpen()
        XCTAssertEqual(opened, desktop.standardizedFileURL)
        first.performOpen()
        XCTAssertEqual(opened, documents.standardizedFileURL)

        controller.displayRows([
            BrowserFileRow(
                url: documents.appendingPathComponent("notes.txt"),
                name: "notes.txt",
                modifiedDate: "Today",
                size: "1 KB",
                kind: "Text",
                isNavigable: false
            )
        ])
        XCTAssertEqual(viewModeControl?.isHidden, false)
    }

    func testVolumeCapacityCaptionUsesFreeSpaceAndUsedFraction() {
        XCTAssertEqual(
            BrowserVolumeCapacity.usedFraction(available: 25, total: 100) ?? -1,
            0.75,
            accuracy: 0.0001
        )
        XCTAssertNil(BrowserVolumeCapacity.usedFraction(available: 10, total: 0))
        let caption = BrowserVolumeCapacity.caption(
            available: 128_000_000_000,
            total: 512_000_000_000
        )
        XCTAssertEqual(
            caption,
            "\(ByteCountFormatter.string(fromByteCount: 128_000_000_000, countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: 512_000_000_000, countStyle: .file))"
        )
        XCTAssertEqual(BrowserLocation.computer.directoryURL, nil)
        XCTAssertEqual(
            BrowserLocation.directory(URL(fileURLWithPath: "/")).directoryURL,
            URL(fileURLWithPath: "/").standardizedFileURL
        )
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
private func mouseDownEvent(clickCount: Int) -> NSEvent {
    NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
    )!
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

@MainActor
private func makeBreadcrumbTestWindow(hosting bar: BrowserBreadcrumbBar) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 30),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    let container = NSView(frame: window.contentView?.bounds ?? .zero)
    container.addSubview(bar)
    window.contentView = container
    NSLayoutConstraint.activate([
        bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        bar.topAnchor.constraint(equalTo: container.topAnchor),
        bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    return window
}

@MainActor
private func sendPrimaryClick(to view: NSView, at point: NSPoint, in window: NSWindow) {
    let windowPoint = view.convert(point, to: nil)
    let event: (NSEvent.EventType, Float) -> NSEvent = { type, pressure in
        NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: pressure
        )!
    }
    NSApp.postEvent(event(.leftMouseUp, 0), atStart: false)
    window.sendEvent(event(.leftMouseDown, 1))
    _ = NSApp.nextEvent(
        matching: .leftMouseUp,
        until: .distantPast,
        inMode: .default,
        dequeue: true
    )
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}
