import AppKit
import ExplorerCore
import ExplorerOperations
import ExplorerUI
import Foundation

@MainActor
protocol ExplorerTabNavigationPresenting: AnyObject {
    var showsHiddenFiles: Bool { get }
    var directorySortDescriptor: FileSortDescriptor { get }

    func prepareToNavigate(leavingHome: Bool, loading destination: BrowserLocation?)
    func presentDirectory(_ snapshot: DirectorySnapshot, overlay: [FileItem], at location: BrowserLocation)
    func presentComputer()
    func presentNavigationFailure(_ message: String, restoreHomePage: Bool)
    func showStatus(_ message: String)
    func requestHomePageRefresh()
}

@MainActor
protocol ExplorerTabFileWorking: AnyObject {
    var selection: Set<URL> { get set }
    var selectedRows: [BrowserFileRow] { get }
    var currentDirectoryURL: URL? { get }
    var viewMode: BrowserViewMode { get }
    var clipboard: FileClipboardService { get }
    var filePromiseQueue: OperationQueue { get }
    var hostWindow: NSWindow? { get }
    var pendingInlineRenameURL: URL? { get set }

    func canPerformFileCommand(_ command: BrowserFileCommand) -> Bool
    func favoriteURLToAdd() -> URL?
    func setViewMode(_ mode: BrowserViewMode)
    func beginRenaming(_ url: URL)
    func showStatus(_ message: String)
    func emit(_ event: ExplorerTabEvent)
    func request(_ location: BrowserLocation, origin: NavigationOrigin)
    func submit(
        _ operation: FileOperation,
        completion: ((FileOperationResult) -> Void)?,
        finished: (() -> Void)?
    )
    func toggleQuickLook()
    func setCutURLs(_ urls: Set<URL>)
}
