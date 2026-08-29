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
                title: BrowserComputerLocation.title,
                url: BrowserComputerLocation.url,
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

    func testDeleteKeyMovesToTrashAndShiftDeleteDeletesPermanently() {
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{7F}",
                specialKey: nil,
                modifiers: []
            ),
            .moveToTrash
        )
        XCTAssertEqual(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{F728}",
                specialKey: .deleteForward,
                modifiers: .shift
            ),
            .deletePermanently
        )
        XCTAssertNil(
            BrowserFileKeyboard.command(
                charactersIgnoringModifiers: "\u{7F}",
                specialKey: nil,
                modifiers: .command
            )
        )
    }

    func testBreadcrumbBarLeavesPathEditingWhenEditingEnds() {
        let bar = BrowserBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        bar.display(URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true))
        bar.focusAddressField()
        XCTAssertTrue(bar.isEditingPath)
        bar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: nil))
        XCTAssertFalse(bar.isEditingPath)
    }

    func testBreadcrumbBarShowsMyComputerForTheHomePage() {
        let bar = BrowserBreadcrumbBar(frame: NSRect(x: 0, y: 0, width: 480, height: 30))
        bar.display(BrowserComputerLocation.url)
        let titles = allDescendants(of: bar, as: NSButton.self).map(\.title)
        XCTAssertEqual(titles.filter { $0 == BrowserComputerLocation.title }, [BrowserComputerLocation.title])
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
        controller.onHomePageOpen = { opened = $0 }
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
        XCTAssertTrue(BrowserComputerLocation.matches(BrowserComputerLocation.url))
        XCTAssertFalse(BrowserComputerLocation.matches(URL(fileURLWithPath: "/")))
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
