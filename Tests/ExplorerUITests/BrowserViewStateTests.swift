import XCTest
@testable import ExplorerUI

final class BrowserViewStateTests: XCTestCase {
    func testPushedStateEnablesCommandsWithoutAskingTheTab() {
        let nested = URL(fileURLWithPath: "/tmp/Photos/Vacation", isDirectory: true)
        let photos = URL(fileURLWithPath: "/tmp/Photos", isDirectory: true)
        let state = BrowserViewState(
            hasSelection: true,
            hasNavigableSelection: true,
            isSingleSelection: true,
            canPaste: false,
            canAddToFavorites: true,
            canAcceptFileURLDrop: true,
            hasCurrentDirectory: true,
            isShowingComputer: false,
            occupiedDirectoryURLs: [photos]
        )

        XCTAssertTrue(state.canPerform(.open))
        XCTAssertTrue(state.canPerform(.openInNewTab))
        XCTAssertTrue(state.canPerform(.addToFavorites))
        XCTAssertTrue(state.canPerform(.rename))
        XCTAssertFalse(state.canPerform(.paste))
        XCTAssertFalse(
            state.canPerform(.openWith(URL(fileURLWithPath: "/Applications/Preview.app")))
        )
        XCTAssertTrue(state.canAddFavorite(at: nested))
        XCTAssertFalse(state.canAddFavorite(at: photos))
        XCTAssertFalse(state.canAddFavorite(at: URL(fileURLWithPath: "/tmp/Photos/")))
    }

    func testSearchSelectionCanOpenAndFavoriteNestedFolders() {
        let state = BrowserViewState(
            hasSelection: true,
            hasNavigableSelection: true,
            isSingleSelection: true,
            canAddToFavorites: true,
            canAcceptFileURLDrop: true,
            hasCurrentDirectory: true
        )

        XCTAssertTrue(state.canPerform(.open))
        XCTAssertTrue(state.canPerform(.openInNewTab))
        XCTAssertTrue(state.canPerform(.addToFavorites))
        XCTAssertFalse(
            state.canPerform(.openWith(URL(fileURLWithPath: "/Applications/Preview.app")))
        )
    }

    func testComputerLocationDisablesDirectoryCommands() {
        let state = BrowserViewState(
            hasSelection: true,
            hasNavigableSelection: true,
            isSingleSelection: true,
            canPaste: false,
            canAcceptFileURLDrop: false,
            hasCurrentDirectory: false,
            isShowingComputer: true
        )

        XCTAssertTrue(state.canPerform(.open))
        XCTAssertFalse(state.canPerform(.newFolder))
        XCTAssertFalse(state.canPerform(.paste))
        XCTAssertFalse(state.canPerform(.rename))
        XCTAssertFalse(state.canAcceptFileURLDrop)
    }

    func testPasteUsesThePushedFlagInsteadOfReaskingTheClipboard() {
        let directory = BrowserViewState(
            canPaste: true,
            canAcceptFileURLDrop: true,
            hasCurrentDirectory: true
        )
        XCTAssertTrue(directory.canPerform(.paste))
        XCTAssertTrue(directory.canPerform(.newFolder))

        let computer = BrowserViewState(
            canPaste: false,
            isShowingComputer: true
        )
        XCTAssertFalse(computer.canPerform(.paste))
    }
}
