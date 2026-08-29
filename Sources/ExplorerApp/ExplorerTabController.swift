import AppKit
import ExplorerBrowsing
import ExplorerCore
import ExplorerOperations
import ExplorerUI
@preconcurrency import QuickLookUI

@MainActor
final class ExplorerTabController: NSViewController, ExplorerTabNavigationPresenting, ExplorerTabFileWorking {
    var onEvent: ((ExplorerTabEvent) -> Void)?

    let browser = ExplorerBrowserViewController()
    private let homeURL: URL
    let searchCoordinator = ExplorerTabSearchCoordinator()
    let thumbnailCoordinator = ExplorerTabThumbnailCoordinator()
    private let operationCoordinator: ExplorerTabOperationCoordinator
    private lazy var quickLookCoordinator = ExplorerQuickLookCoordinator(owner: self)
    let clipboard: FileClipboardService
    private let initialSidebarWidth: CGFloat?
    private let navigation = ExplorerTabNavigationCoordinator()
    private let files = ExplorerTabFileCoordinator()
    private let sidebar = ExplorerTabSidebarCoordinator()
    private(set) var viewMode: BrowserViewMode
    private(set) var sortDescriptor: BrowserSortDescriptor
    private(set) var showsPreview: Bool
    private(set) var showsHiddenFiles: Bool
    var selection: Set<URL> = []
    private var contentState = ExplorerTabContentState()
    private var didStart = false
    var pendingInlineRenameURL: URL?
    var homePageModel: BrowserHomePageModel
    var occupiedDirectoryURLs: Set<URL> = []
    let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.explorer.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var currentLocation: BrowserLocation? { navigation.currentLocation }
    var currentDirectoryURL: URL? { navigation.currentDirectoryURL }
    var isShowingComputer: Bool { navigation.isShowingComputer }
    var directorySortDescriptor: FileSortDescriptor { sortDescriptor.fileSortDescriptor }
    var hostWindow: NSWindow? { view.window }

    init(
        homeURL: URL,
        sidebarLocations: [BrowserSidebarLocation],
        initialViewMode: BrowserViewMode,
        initialSortDescriptor: BrowserSortDescriptor,
        initialShowsPreview: Bool,
        initialShowsHiddenFiles: Bool,
        sidebarWidth: CGFloat?,
        homePageModel: BrowserHomePageModel = .empty,
        operationQueue: FileOperationQueue,
        clipboard: FileClipboardService
    ) {
        self.homeURL = homeURL
        viewMode = initialViewMode
        sortDescriptor = initialSortDescriptor
        showsPreview = initialShowsPreview
        showsHiddenFiles = initialShowsHiddenFiles
        initialSidebarWidth = sidebarWidth
        self.homePageModel = homePageModel
        operationCoordinator = ExplorerTabOperationCoordinator(queue: operationQueue)
        self.clipboard = clipboard
        super.init(nibName: nil, bundle: nil)
        navigation.presenter = self
        files.host = self
        sidebar.onFolders = { [weak self] folders, parent in
            self?.browser.displaySidebarChildren(folders, for: parent)
        }
        sidebar.onFailure = { [weak self] message in
            self?.browser.showStatus(message)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fileClipboardDidChange(_:)),
            name: FileClipboardService.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        browser.displaySidebarLocations(sidebarLocations)
        browser.setViewMode(initialViewMode)
        browser.setSortDescriptor(initialSortDescriptor)
        browser.setPreviewVisible(initialShowsPreview)
        files.synchronizeCutPresentation()
        configureCallbacks()
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        view = container

        addChild(browser)
        let browserView = browser.view
        browserView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(browserView)
        NSLayoutConstraint.activate([
            browserView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            browserView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            browserView.topAnchor.constraint(equalTo: container.topAnchor),
            browserView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        browser.setSortDescriptor(sortDescriptor)
        if let initialSidebarWidth { browser.setSidebarWidth(initialSidebarWidth) }
    }

    var displayTitle: String {
        currentLocation?.displayTitle ?? "Loading…"
    }

    var selectedRows: [BrowserFileRow] {
        contentState.selectedItems(for: selection).map(BrowserFileRow.init)
    }

    func start(at location: BrowserLocation) {
        guard !didStart else { return }
        didStart = true
        navigation.request(location, origin: .newLocation)
    }

    func cancelLoading() {
        searchCoordinator.cancel()
        thumbnailCoordinator.cancelAll()
        navigation.cancelAll()
        sidebar.cancelAll()
    }

    func setViewMode(_ mode: BrowserViewMode) {
        guard !isShowingComputer else { return }
        viewMode = mode
        browser.setViewMode(mode)
        if mode == .details { thumbnailCoordinator.cancelAll() }
        emit(.viewModeChange(mode))
    }

    var canChangeViewMode: Bool { !isShowingComputer }

    func setSortDescriptor(_ descriptor: BrowserSortDescriptor) {
        guard sortDescriptor != descriptor else { return }
        sortDescriptor = descriptor
        browser.setSortDescriptor(descriptor)
        navigation.perform(.refresh)
    }

    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) {
        guard self.showsHiddenFiles != showsHiddenFiles else { return }
        self.showsHiddenFiles = showsHiddenFiles
        navigation.perform(.refresh)
    }

    func setPreviewVisible(_ isVisible: Bool) {
        guard showsPreview != isVisible else { return }
        showsPreview = isVisible
        browser.setPreviewVisible(isVisible)
        emit(.previewVisibilityChange(isVisible))
    }

    func togglePreview() {
        setPreviewVisible(!showsPreview)
    }

    func updateSidebarLocations(_ locations: [BrowserSidebarLocation]) {
        browser.displaySidebarLocations(locations)
    }

    func updateHomePage(_ model: BrowserHomePageModel) {
        homePageModel = model
        if isShowingComputer, !navigation.isLoadingDirectory {
            browser.displayHomePage(model)
        }
    }

    func setOccupiedDirectoryURLs(_ urls: Set<URL>) {
        occupiedDirectoryURLs = urls
        pushViewState()
    }

    func showStatus(_ message: String) { browser.showStatus(message) }
    func refreshContents() { navigation.perform(.refresh) }

    func prepareToNavigate(leavingHome: Bool, loading destination: BrowserLocation?) {
        thumbnailCoordinator.cancelAll()
        searchCoordinator.cancel()
        browser.clearSearchField()
        if leavingHome, let destination {
            browser.beginLeavingHomePage(loading: destination)
        }
        if let url = destination?.directoryURL {
            browser.showStatus("Loading \(url.path)…")
        }
    }

    func presentDirectory(_ snapshot: DirectorySnapshot, overlay: [FileItem], at location: BrowserLocation) {
        contentState.showDirectory(snapshot, overlay: overlay)
        let visibleItems = contentState.visibleItems.sorted(using: sortDescriptor.fileSortDescriptor)
        selection.formIntersection(Set(visibleItems.map(\.url)))
        if let pendingInlineRenameURL,
           visibleItems.contains(where: { $0.url == pendingInlineRenameURL }) {
            selection = [pendingInlineRenameURL]
        }
        browser.displayLocation(location, trail: ExplorerTabNavigation.breadcrumbTrail(for: location))
        browser.displayRows(visibleItems.map(BrowserFileRow.init), selecting: selection)
        if let pendingInlineRenameURL,
           visibleItems.contains(where: { $0.url == pendingInlineRenameURL }) {
            self.pendingInlineRenameURL = nil
            if viewMode != .details { setViewMode(.details) }
            browser.beginRenaming(pendingInlineRenameURL)
        }
        emit(.titleChange(displayTitle))
        pushViewState()
        let label = "\(visibleItems.count) \(visibleItems.count == 1 ? "item" : "items")"
        browser.showStatus(
            snapshot.issues.isEmpty ? label : "\(label); \(snapshot.issues.count) item(s) could not be read."
        )
    }

    func presentComputer() {
        contentState.showHome()
        selection = []
        pendingInlineRenameURL = nil
        browser.displayHomePage(homePageModel)
        browser.selectSidebarLocation(.computer)
        emit(.titleChange(displayTitle))
        pushViewState()
    }

    func presentNavigationFailure(_ message: String, restoreHomePage: Bool) {
        browser.showStatus(message)
        if restoreHomePage {
            browser.displayHomePage(homePageModel)
        }
    }

    func requestHomePageRefresh() {
        emit(.homePageRefresh)
    }

    func beginRenaming(_ url: URL) { browser.beginRenaming(url) }
    func setCutURLs(_ urls: Set<URL>) { browser.setCutURLs(urls) }

    func canPerformFileCommand(_ command: BrowserFileCommand) -> Bool {
        browser.viewState.canPerform(command)
    }

    func performFileCommand(_ command: BrowserFileCommand) {
        files.perform(command)
    }

    func perform(_ command: BrowserNavigationCommand) {
        navigation.perform(command)
    }

    func request(_ location: BrowserLocation, origin: NavigationOrigin) {
        navigation.request(location, origin: origin)
    }

    func handleOperationEvent(_ event: FileOperationQueueEvent) {
        operationCoordinator.handle(event)
    }

    func emit(_ event: ExplorerTabEvent) {
        onEvent?(event)
    }

    func pushViewState() {
        browser.viewState = makeViewState()
    }

    func favoriteURLToAdd() -> URL? {
        guard selection.count == 1, let row = selectedRows.first, row.isNavigable else { return nil }
        guard !occupiedDirectoryURLs.contains(row.url.standardizedFileURL) else { return nil }
        return row.url
    }

    func submit(
        _ operation: FileOperation,
        completion: ((FileOperationResult) -> Void)? = nil,
        finished: (() -> Void)? = nil
    ) {
        operationCoordinator.submit(
            operation,
            window: view.window,
            completion: completion,
            finished: finished
        )
    }

    func loadSidebarChildren(of parentURL: URL) {
        sidebar.loadChildren(of: parentURL, showsHiddenFiles: showsHiddenFiles)
    }

    private func configureCallbacks() {
        browser.onAction = { [weak self] action in
            self?.handle(action) ?? false
        }
        operationCoordinator.onStatus = { [weak self] message in
            self?.browser.showStatus(message)
        }
        operationCoordinator.onCompleted = { [weak self] operation, result in
            self?.emit(.operationCompleted(operation, result))
        }
        operationCoordinator.onRefresh = { [weak self] in self?.navigation.perform(.refresh) }
        searchCoordinator.onResults = { [weak self] items, query, isComplete in
            self?.displaySearchResults(items, query: query, isComplete: isComplete)
        }
        searchCoordinator.onFailure = { [weak self] error in
            self?.browser.showStatus(error.localizedDescription)
        }
        thumbnailCoordinator.onThumbnail = { [weak self] thumbnail, url in
            self?.browser.displayThumbnail(thumbnail.data, for: url)
        }
        pushViewState()
    }

    @discardableResult
    private func handle(_ action: BrowserAction) -> Bool {
        switch action {
        case let .navigation(command):
            navigation.perform(command)
        case let .file(command):
            files.perform(command)
        case let .openLocation(location):
            navigation.request(location, origin: .newLocation)
        case let .openFileRow(row):
            files.open(row)
        case let .submitPath(path):
            navigation.request(
                .directory(navigation.url(forSubmittedPath: path, homeURL: homeURL)),
                origin: .newLocation
            )
        case let .expandSidebar(url):
            loadSidebarChildren(of: url)
        case let .openLocationInNewTab(location):
            emit(.openLocationInNewTab(location))
        case let .createFolder(parent):
            files.createNewFolder(in: parent)
        case let .trash(url):
            submit(.trash(sources: [url])) { [weak self] _ in
                self?.loadSidebarChildren(of: url.deletingLastPathComponent())
            }
        case let .removeFavorite(url):
            emit(.removeFavorite(url))
        case let .addFavorite(url):
            emit(.addFavorite(url))
        case let .copyPath(url):
            files.copyPaths([url])
        case let .revealInFinder(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case let .rename(source, name):
            submit(.rename(source: source, name: name, conflictPolicy: .ask)) { [weak self] result in
                guard let destination = result.items.first(where: { $0.status == .completed })?.destination else { return }
                self?.selection = [destination]
                self?.pushViewState()
            }
        case let .selectionChange(urls):
            selection = urls
            updateQuickLookSelection()
            pushViewState()
        case let .sidebarWidthChange(width):
            emit(.sidebarWidthChange(width))
        case let .search(query):
            filterCurrentDirectory(matching: query)
        case .clearSearch:
            restoreUnfilteredSnapshot()
        case let .requestThumbnail(url):
            thumbnailCoordinator.request(url, scale: Double(NSScreen.main?.backingScaleFactor ?? 2))
        case let .cancelThumbnail(url):
            thumbnailCoordinator.cancel(url)
        case let .setViewMode(mode):
            setViewMode(mode)
        case let .setSort(descriptor):
            setSortDescriptor(descriptor)
        case let .dropFiles(drop):
            return files.accept(drop)
        case let .dropPromisedFiles(drop):
            return files.accept(drop)
        }
        return true
    }

    private func makeViewState() -> BrowserViewState {
        let rows = selectedRows
        let inDirectory = currentDirectoryURL != nil && !isShowingComputer
        return BrowserViewState(
            hasSelection: !rows.isEmpty,
            hasNavigableSelection: rows.contains(where: \.isNavigable),
            isSingleSelection: rows.count == 1,
            canPaste: inDirectory && clipboard.read() != nil,
            canAddToFavorites: favoriteURLToAdd() != nil,
            canAcceptFileURLDrop: inDirectory,
            hasCurrentDirectory: currentDirectoryURL != nil,
            isShowingComputer: isShowingComputer,
            occupiedDirectoryURLs: occupiedDirectoryURLs,
            openWithApplications: WorkspaceOpenWith.applications(for: rows)
        )
    }

    private func filterCurrentDirectory(matching text: String) {
        guard let currentSnapshot = contentState.baseSnapshot else {
            if isShowingComputer {
                browser.showStatus("Search is not available on My Computer.")
            } else {
                browser.showStatus("Wait for the folder to finish loading before searching.")
            }
            return
        }
        searchCoordinator.search(
            snapshot: currentSnapshot,
            visibleItems: contentState.visibleItems,
            additionalSubtreeRoots: contentState.overlayDirectoryURLs,
            text: text,
            includesHiddenFiles: showsHiddenFiles
        )
    }

    private func displaySearchResults(_ items: [FileItem], query: String, isComplete: Bool) {
        guard contentState.showSearchResults(items, query: query, isComplete: isComplete) else { return }
        selection.formIntersection(Set(items.map(\.url)))
        browser.displayRows(items.map(BrowserFileRow.init), selecting: selection)
        pushViewState()
        let noun = items.count == 1 ? "match" : "matches"
        if isComplete {
            browser.showStatus("\(items.count) \(noun) for “\(query)”.")
        } else {
            browser.showStatus("Searching for “\(query)”… \(items.count) \(noun) so far.")
        }
    }

    private func restoreUnfilteredSnapshot() {
        searchCoordinator.cancel()
        if isShowingComputer {
            browser.displayHomePage(homePageModel)
            return
        }
        guard contentState.baseSnapshot != nil else { return }
        contentState.restoreDirectory()
        let visibleItems = contentState.visibleItems.sorted(using: sortDescriptor.fileSortDescriptor)
        selection.formIntersection(Set(visibleItems.map(\.url)))
        browser.displayRows(visibleItems.map(BrowserFileRow.init), selecting: selection)
        pushViewState()
        let label = "\(visibleItems.count) \(visibleItems.count == 1 ? "item" : "items")"
        browser.showStatus(label)
    }

    @objc private func fileClipboardDidChange(_ notification: Notification) {
        files.synchronizeCutPresentation()
        pushViewState()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        files.synchronizeCutPresentation()
        pushViewState()
    }

    func closeQuickLook() {
        quickLookCoordinator.close()
    }

    func updateQuickLookSelection() {
        quickLookCoordinator.updateSelection(selection)
    }

    func beginQuickLookControl(_ panel: QLPreviewPanel) {
        quickLookCoordinator.beginControl(panel, selection: selection)
    }

    var canAcceptQuickLookControl: Bool { !selection.isEmpty }

    func toggleQuickLook() {
        quickLookCoordinator.toggle(selection: selection)
    }
}

extension ExplorerTabController {
    @objc nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { canAcceptQuickLookControl }
    }

    @objc nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            beginQuickLookControl(panel)
        }
    }

    @objc nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // The shared panel may transfer to another tab through the responder
        // chain; no filesystem state is retained by the preview controller.
    }
}

private enum WorkspaceOpenWith {
    static let maximumApplications = 12

    static func applications(for rows: [BrowserFileRow]) -> [BrowserOpenWithApplication] {
        guard rows.count == 1, let row = rows.first, !row.isNavigable else { return [] }
        return applications(for: row.url)
    }

    static func applications(for url: URL) -> [BrowserOpenWithApplication] {
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: url)?.standardizedFileURL
        var seen = Set<URL>()
        let apps = workspace.urlsForApplications(toOpen: url).compactMap { application -> BrowserOpenWithApplication? in
            let applicationURL = application.standardizedFileURL
            guard seen.insert(applicationURL).inserted else { return nil }
            return BrowserOpenWithApplication(
                url: applicationURL,
                name: FileManager.default.displayName(atPath: applicationURL.path),
                isDefault: applicationURL == defaultApp
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return Array(apps.prefix(maximumApplications))
    }
}
