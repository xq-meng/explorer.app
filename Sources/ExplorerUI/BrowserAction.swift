import Foundation

/// User intents emitted by the browser chrome. The view never performs
/// filesystem work; the tab coordinator interprets each case.
public enum BrowserAction {
    case navigation(BrowserNavigationCommand)
    case file(BrowserFileCommand)
    case openLocation(BrowserLocation)
    case openFileRow(BrowserFileRow)
    case submitPath(String)
    case openLocationInNewTab(BrowserLocation)
    case createFolder(in: URL)
    case trash(URL)
    case removeFavorite(URL)
    case addFavorite(URL)
    case copyPath(URL)
    case revealInFinder(URL)
    case rename(source: URL, name: String)
    case selectionChange(Set<URL>)
    case sidebarWidthChange(CGFloat)
    case search(String)
    case clearSearch
    case requestThumbnail(URL)
    case cancelThumbnail(URL)
    case setViewMode(BrowserViewMode)
    case setSort(BrowserSortDescriptor)
    case dropFiles(BrowserFileDrop)
    case dropPromisedFiles(BrowserPromisedFileDrop)
}

/// Immutable command, menu, and drop capabilities pushed into the browser
/// when the tab's location, selection, clipboard, or sidebar occupancy changes.
public struct BrowserViewState: Equatable, Sendable {
    public var hasSelection: Bool
    public var hasNavigableSelection: Bool
    public var isSingleSelection: Bool
    public var canPaste: Bool
    public var canAddToFavorites: Bool
    public var canAcceptFileURLDrop: Bool
    public var hasCurrentDirectory: Bool
    public var isShowingComputer: Bool
    public var occupiedDirectoryURLs: Set<URL>
    public var openWithApplications: [BrowserOpenWithApplication]

    public init(
        hasSelection: Bool = false,
        hasNavigableSelection: Bool = false,
        isSingleSelection: Bool = false,
        canPaste: Bool = false,
        canAddToFavorites: Bool = false,
        canAcceptFileURLDrop: Bool = false,
        hasCurrentDirectory: Bool = false,
        isShowingComputer: Bool = false,
        occupiedDirectoryURLs: Set<URL> = [],
        openWithApplications: [BrowserOpenWithApplication] = []
    ) {
        self.hasSelection = hasSelection
        self.hasNavigableSelection = hasNavigableSelection
        self.isSingleSelection = isSingleSelection
        self.canPaste = canPaste
        self.canAddToFavorites = canAddToFavorites
        self.canAcceptFileURLDrop = canAcceptFileURLDrop
        self.hasCurrentDirectory = hasCurrentDirectory
        self.isShowingComputer = isShowingComputer
        self.occupiedDirectoryURLs = occupiedDirectoryURLs
        self.openWithApplications = openWithApplications
    }

    public static let empty = BrowserViewState()

    public func canAddFavorite(at url: URL) -> Bool {
        !occupiedDirectoryURLs.contains(url.standardizedFileURL)
    }

    public func canPerform(_ command: BrowserFileCommand) -> Bool {
        switch command {
        case .open:
            hasSelection
        case .openInNewTab:
            hasNavigableSelection
        case .openWith:
            isSingleSelection && !hasNavigableSelection
        case .revealInFinder, .copyPath, .newFolder:
            hasCurrentDirectory && !isShowingComputer
        case .addToFavorites:
            canAddToFavorites
        case .rename:
            hasCurrentDirectory && !isShowingComputer && isSingleSelection
        case .copy, .cut, .duplicate, .moveToTrash, .deletePermanently:
            hasSelection
        case .paste:
            canPaste
        case .quickLook:
            hasSelection
        }
    }
}
