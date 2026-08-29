import ExplorerCore
import ExplorerUI
import Foundation
import XCTest
@testable import ExplorerApp

final class ExplorerTabContentTests: XCTestCase {
    func testSelectedItemsComeFromSearchResultsNotTheBaseSnapshot() {
        let folder = URL(fileURLWithPath: "/tmp/Photos", isDirectory: true)
        let nested = URL(fileURLWithPath: "/tmp/Photos/Vacation/IMG_1001.png")
        let snapshot = DirectorySnapshot(
            directoryURL: folder,
            items: [fileItem(url: folder.appendingPathComponent("Album"), kind: .directory)]
        )
        var state = ExplorerTabContentState()
        state.showDirectory(snapshot)
        XCTAssertTrue(state.selectedItems(for: [nested]).isEmpty)

        XCTAssertTrue(state.showSearchResults([fileItem(url: nested, kind: .file)], query: "IMG", isComplete: true))
        let selected = state.selectedItems(for: [nested])
        XCTAssertEqual(selected.map(\.url), [nested])
        XCTAssertEqual(selected.first?.name, "IMG_1001.png")
    }

    func testOverlayItemsStayOutOfTheDirectorySnapshot() {
        let cloudDocs = URL(fileURLWithPath: "/tmp/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let library = URL(fileURLWithPath: "/tmp/Mobile Documents/iCloud~notes/Documents", isDirectory: true)
        let snapshot = DirectorySnapshot(
            directoryURL: cloudDocs,
            items: [fileItem(url: cloudDocs.appendingPathComponent("Downloads"), kind: .directory)]
        )
        var state = ExplorerTabContentState()
        state.showDirectory(snapshot, overlay: [fileItem(url: library, name: "Notes", kind: .directory)])
        XCTAssertEqual(state.baseSnapshot?.items.map(\.name), ["Downloads"])
        XCTAssertEqual(state.visibleItems.map(\.name), ["Downloads", "Notes"])
        XCTAssertEqual(state.overlayDirectoryURLs, [library])
    }
}

final class ExplorerTabNavigationTests: XCTestCase {
    func testUpFromICloudLibraryGoesToICloudDrive() {
        let documents = URL(
            fileURLWithPath: "/Users/demo/Library/Mobile Documents/iCloud~ws~stash~icloud/Documents",
            isDirectory: true
        )
        XCTAssertEqual(
            ExplorerTabNavigation.parent(of: .directory(documents)),
            .directory(
                URL(
                    fileURLWithPath: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs",
                    isDirectory: true
                )
            )
        )
    }

    func testUpFromICloudDriveGoesToMyComputer() {
        let cloudDocs = URL(
            fileURLWithPath: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs",
            isDirectory: true
        )
        XCTAssertEqual(ExplorerTabNavigation.parent(of: .directory(cloudDocs)), .computer)
        XCTAssertNil(ExplorerTabNavigation.parent(of: .computer))
    }
}

private func fileItem(url: URL, name: String? = nil, kind: FileKind) -> FileItem {
    FileItem(
        id: FileItemID(volumeIdentifier: nil, resourceIdentifier: nil, fallbackURL: url),
        url: url,
        name: name ?? url.lastPathComponent,
        kind: kind,
        size: nil,
        creationDate: nil,
        modificationDate: nil,
        isHidden: false,
        isPackage: false,
        isSymbolicLink: false,
        isReadable: true,
        isWritable: true
    )
}
