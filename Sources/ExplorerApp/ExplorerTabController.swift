import AppKit
import ExplorerBrowsing
import ExplorerCore
import ExplorerOperations
import ExplorerUI
@preconcurrency import QuickLookUI

@MainActor
final class ExplorerTabController: NSViewController {
    var onTitleChange: ((String) -> Void)?
    var onViewModeChange: ((BrowserViewMode) -> Void)?
    var onSortChange: ((BrowserSortDescriptor) -> Void)?
    var onPreviewVisibilityChange: ((Bool) -> Void)?
    var onSidebarWidthChange: ((CGFloat) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var onOperationCompleted: ((FileOperation, FileOperationResult) -> Void)?
    var onOpenLocationInNewTab: ((URL) -> Void)?
    var onRemoveFavorite: ((URL) -> Void)?
    var onAddFavorite: ((URL) -> Void)?
    var canAddFavorite: ((URL) -> Bool)?

    private let browser = ExplorerBrowserViewController()
    private let homeURL: URL
    private let directoryLoader = DirectoryLoader()
    private let sidebarLoader = DirectoryLoader()
    private let searchCoordinator = ExplorerTabSearchCoordinator()
    private let thumbnailCoordinator = ExplorerTabThumbnailCoordinator()
    private let operationCoordinator: ExplorerTabOperationCoordinator
    private lazy var quickLookCoordinator = ExplorerQuickLookCoordinator(owner: self)
    private let clipboard: FileClipboardService
    private let initialSidebarWidth: CGFloat?
    private(set) var currentDirectoryURL: URL?
    private(set) var viewMode: BrowserViewMode
    private(set) var sortDescriptor: BrowserSortDescriptor
    private(set) var showsPreview: Bool
    private(set) var showsHiddenFiles: Bool
    private var navigationHistory = NavigationHistory()
    private var selection: Set<URL> = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt = 0
    private var currentSnapshot: DirectorySnapshot?
    private var directoryMonitor: DirectoryChangeMonitor?
    private var monitorTask: Task<Void, Never>?
    private var monitorGeneration: UInt = 0
    private var didStart = false
    private var sidebarLoadTasks: [URL: Task<Void, Never>] = [:]
    private var pendingInlineRenameURL: URL?
    private let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.explorer.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(
        homeURL: URL,
        sidebarLocations: [BrowserSidebarLocation],
        initialViewMode: BrowserViewMode,
        initialSortDescriptor: BrowserSortDescriptor,
        initialShowsPreview: Bool,
        initialShowsHiddenFiles: Bool,
        sidebarWidth: CGFloat?,
        operationQueue: FileOperationQueue,
        clipboard: FileClipboardService
    ) {
        self.homeURL = homeURL
        viewMode = initialViewMode
        sortDescriptor = initialSortDescriptor
        showsPreview = initialShowsPreview
        showsHiddenFiles = initialShowsHiddenFiles
        initialSidebarWidth = sidebarWidth
        operationCoordinator = ExplorerTabOperationCoordinator(queue: operationQueue)
        self.clipboard = clipboard
        super.init(nibName: nil, bundle: nil)
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
        synchronizeCutPresentation()
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

    deinit {
        loadTask?.cancel()
        monitorTask?.cancel()
        sidebarLoadTasks.values.forEach { $0.cancel() }
    }

    var displayTitle: String {
        guard let currentDirectoryURL else { return "Loading…" }
        return currentDirectoryURL.lastPathComponent.isEmpty ? currentDirectoryURL.path : currentDirectoryURL.lastPathComponent
    }

    var selectedURLs: Set<URL> { selection }

    func start(at url: URL) {
        guard !didStart else { return }
        didStart = true
        requestDirectory(url, origin: .newLocation)
    }

    func cancelLoading() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        searchCoordinator.cancel()
        thumbnailCoordinator.cancelAll()
        stopMonitoring()
        sidebarLoadTasks.values.forEach { $0.cancel() }
        sidebarLoadTasks.removeAll()
    }

    func setViewMode(_ mode: BrowserViewMode) {
        viewMode = mode
        browser.setViewMode(mode)
        if mode == .details { thumbnailCoordinator.cancelAll() }
        onViewModeChange?(mode)
    }

    func setSortDescriptor(_ descriptor: BrowserSortDescriptor) {
        guard sortDescriptor != descriptor else { return }
        sortDescriptor = descriptor
        browser.setSortDescriptor(descriptor)
        onSortChange?(descriptor)
        perform(.refresh)
    }

    func setShowsHiddenFiles(_ showsHiddenFiles: Bool) {
        guard self.showsHiddenFiles != showsHiddenFiles else { return }
        self.showsHiddenFiles = showsHiddenFiles
        perform(.refresh)
    }

    func setPreviewVisible(_ isVisible: Bool) {
        guard showsPreview != isVisible else { return }
        showsPreview = isVisible
        browser.setPreviewVisible(isVisible)
        onPreviewVisibilityChange?(isVisible)
    }

    func togglePreview() {
        setPreviewVisible(!showsPreview)
    }

    func updateSidebarLocations(_ locations: [BrowserSidebarLocation]) {
        browser.displaySidebarLocations(locations)
    }

    func showStatus(_ message: String) { browser.showStatus(message) }
    func refreshContents() { perform(.refresh) }

    func canPerformFileCommand(_ command: BrowserFileCommand) -> Bool {
        switch command {
        case .open: !selection.isEmpty
        case .openInNewTab: selectedRows.contains(where: \.isNavigable)
        case .openWith: selection.count == 1 && selectedRows.contains(where: { !$0.isNavigable })
        case .revealInFinder, .copyPath, .newFolder: currentDirectoryURL != nil
        case .addToFavorites: favoriteURLToAdd() != nil
        case .rename: currentDirectoryURL != nil && selection.count == 1
        case .copy, .cut, .duplicate, .moveToTrash: !selection.isEmpty
        case .paste: currentDirectoryURL != nil && clipboard.read() != nil
        case .quickLook: !selection.isEmpty
        }
    }

    func performFileCommand(_ command: BrowserFileCommand) {
        guard canPerformFileCommand(command) else { return }
        switch command {
        case .open:
            openSelection()
        case .openInNewTab:
            selectedRows.filter(\.isNavigable).forEach { onOpenLocationInNewTab?($0.url) }
        case let .openWith(applicationURL):
            openSelection(with: applicationURL)
        case .revealInFinder:
            let urls = selection.isEmpty ? [currentDirectoryURL].compactMap { $0 } : Array(selection)
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .copyPath:
            copyPaths(selection.isEmpty ? [currentDirectoryURL].compactMap { $0 } : Array(selection))
        case .addToFavorites:
            guard let url = favoriteURLToAdd() else { return }
            onAddFavorite?(url)
        case .newFolder:
            guard let currentDirectoryURL else { return }
            createNewFolder(in: currentDirectoryURL)
        case .rename:
            guard let source = selection.first else { return }
            if viewMode != .details { setViewMode(.details) }
            browser.beginRenaming(source)
        case .copy:
            writeClipboard(intent: .copy)
        case .cut:
            writeClipboard(intent: .cut)
        case .paste:
            pasteClipboardContents()
        case .duplicate:
            guard let currentDirectoryURL else { return }
            for source in selection {
                // Duplication explicitly requests a sibling-safe name rather
                // than replacing an existing item.
                submit(.duplicate(source: source, to: currentDirectoryURL, conflictPolicy: .keepBoth))
            }
        case .moveToTrash:
            submit(.trash(sources: Array(selection)))
        case .quickLook:
            toggleQuickLook()
        }
    }

    func handleOperationEvent(_ event: FileOperationQueueEvent) {
        operationCoordinator.handle(event)
    }

    func perform(_ command: BrowserNavigationCommand) {
        switch command {
        case .back:
            guard let previous = navigationHistory.previous else { browser.showStatus("No earlier folder in history."); return }
            requestDirectory(previous, origin: .back)
        case .forward:
            guard let next = navigationHistory.next else { browser.showStatus("No later folder in history."); return }
            requestDirectory(next, origin: .forward)
        case .up:
            guard let currentDirectoryURL else { requestDirectory(homeURL, origin: .newLocation); return }
            let parent = currentDirectoryURL.deletingLastPathComponent().standardizedFileURL
            guard parent != currentDirectoryURL else { browser.showStatus("Already at the top-level folder."); return }
            requestDirectory(parent, origin: .newLocation)
        case .refresh:
            requestDirectory(currentDirectoryURL ?? homeURL, origin: .refresh)
        }
    }

    private func configureCallbacks() {
        operationCoordinator.onStatus = { [weak self] message in
            self?.browser.showStatus(message)
        }
        operationCoordinator.onCompleted = { [weak self] operation, result in
            self?.onOperationCompleted?(operation, result)
        }
        operationCoordinator.onRefresh = { [weak self] in self?.perform(.refresh) }
        searchCoordinator.onResults = { [weak self] items, query, isComplete in
            self?.displaySearchResults(items, query: query, isComplete: isComplete)
        }
        searchCoordinator.onFailure = { [weak self] error in
            self?.browser.showStatus(error.localizedDescription)
        }
        thumbnailCoordinator.onThumbnail = { [weak self] thumbnail, url in
            self?.browser.displayThumbnail(thumbnail.data, for: url)
        }
        browser.onNavigationCommand = { [weak self] command in self?.perform(command) }
        browser.onViewModeSelection = { [weak self] mode in self?.setViewMode(mode) }
        browser.onSortSelection = { [weak self] descriptor in self?.setSortDescriptor(descriptor) }
        browser.onPathSubmission = { [weak self] path in
            guard let self else { return }
            self.requestDirectory(self.url(forSubmittedPath: path), origin: .newLocation)
        }
        browser.onBreadcrumbSelection = { [weak self] url in
            self?.requestDirectory(url, origin: .newLocation)
        }
        browser.onSidebarLocationSelection = { [weak self] location in self?.requestDirectory(location.url, origin: .newLocation) }
        browser.onSidebarExpansionRequest = { [weak self] url in self?.loadSidebarChildren(of: url) }
        browser.onOpenSidebarLocationInNewTab = { [weak self] url in self?.onOpenLocationInNewTab?(url) }
        browser.onCreateFolderInSidebarLocation = { [weak self] url in self?.createNewFolder(in: url) }
        browser.onMoveSidebarLocationToTrash = { [weak self] url in
            self?.submit(.trash(sources: [url])) { [weak self] _ in
                self?.loadSidebarChildren(of: url.deletingLastPathComponent())
            }
        }
        browser.onRemoveSidebarFavorite = { [weak self] url in self?.onRemoveFavorite?(url) }
        browser.onOpenFileRow = { [weak self] row in self?.open(row) }
        browser.onRenameSubmission = { [weak self] source, name in
            self?.submit(.rename(source: source, name: name, conflictPolicy: .ask)) { [weak self] result in
                guard let destination = result.items.first(where: { $0.status == .completed })?.destination else { return }
                self?.selection = [destination]
            }
        }
        browser.onSelectionChange = { [weak self] urls in
            self?.selection = urls
            self?.onSelectionChange?(urls)
            self?.updateQuickLookSelection()
        }
        browser.onSidebarWidthChange = { [weak self] width in self?.onSidebarWidthChange?(width) }
        browser.onSearchQueryChange = { [weak self] query in self?.filterCurrentDirectory(matching: query) }
        browser.onSearchClear = { [weak self] in self?.restoreUnfilteredSnapshot() }
        browser.onThumbnailRequest = { [weak self] url in
            guard let self else { return }
            self.thumbnailCoordinator.request(
                url,
                scale: Double(NSScreen.main?.backingScaleFactor ?? 2)
            )
        }
        browser.onThumbnailCancellation = { [weak self] url in
            self?.thumbnailCoordinator.cancel(url)
        }
        browser.onFileCommand = { [weak self] command in self?.performFileCommand(command) }
        browser.canPerformFileCommand = { [weak self] command in self?.canPerformFileCommand(command) ?? false }
        browser.contextMenuState = { [weak self] in self?.makeContextMenuState() ?? .empty }
        browser.onFileURLDrop = { [weak self] drop in self?.accept(drop) ?? false }
        browser.onPromisedFileDrop = { [weak self] drop in self?.accept(drop) ?? false }
        browser.canAcceptFileURLDrop = { [weak self] in self?.currentDirectoryURL != nil }
        browser.onCopySidebarPath = { [weak self] url in self?.copyPaths([url]) }
        browser.onRevealSidebarInFinder = { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        browser.onAddSidebarFavorite = { [weak self] url in self?.onAddFavorite?(url) }
        browser.canAddSidebarFavorite = { [weak self] url in self?.canAddFavorite?(url) ?? false }
    }

    private func loadSidebarChildren(of parentURL: URL) {
        let parent = parentURL.standardizedFileURL
        sidebarLoadTasks[parent]?.cancel()
        let loader = sidebarLoader
        let options = sidebarLoadOptions
        sidebarLoadTasks[parent] = Task { [weak self] in
            defer { self?.sidebarLoadTasks[parent] = nil }
            do {
                let snapshot = try await loader.load(parent, options: options)
                guard !Task.isCancelled, let self else { return }
                let folders = Self.sidebarFolders(from: snapshot)
                self.browser.displaySidebarChildren(folders, for: parent)
            } catch is CancellationError {
            } catch FileProviderError.cancelled {
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.browser.displaySidebarChildren([], for: parent)
                self.browser.showStatus("Unable to expand \(parent.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private static func sidebarFolders(from snapshot: DirectorySnapshot) -> [BrowserSidebarLocation] {
        snapshot.items.compactMap { item in
            guard item.kind == .directory, !item.isPackage, !item.isSymbolicLink else { return nil }
            return BrowserSidebarLocation(title: item.name, url: item.url)
        }
    }

    private func requestDirectory(_ url: URL, origin: NavigationOrigin) {
        let destination = url.standardizedFileURL
        thumbnailCoordinator.cancelAll()
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        if origin != .refresh { stopMonitoring() }
        searchCoordinator.cancel()
        browser.clearSearchField()
        browser.showStatus("Loading \(destination.path)…")
        let loader = directoryLoader
        let options = directoryLoadOptions
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await loader.load(destination, options: options)
                guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
                self.apply(snapshot, destination: destination, origin: origin)
            } catch is CancellationError {
            } catch FileProviderError.cancelled {
            } catch {
                guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
                self.browser.showStatus(error.localizedDescription)
                if let currentDirectoryURL = self.currentDirectoryURL { self.startMonitoring(currentDirectoryURL) }
            }
        }
    }

    private func apply(_ snapshot: DirectorySnapshot, destination: URL, origin: NavigationOrigin) {
        guard navigationHistory.commit(
            origin: origin,
            current: currentDirectoryURL,
            destination: destination
        ) else { return }
        currentDirectoryURL = snapshot.directoryURL
        currentSnapshot = snapshot
        selection.formIntersection(Set(snapshot.items.map(\.url)))
        if let pendingInlineRenameURL,
           snapshot.items.contains(where: { $0.url == pendingInlineRenameURL }) {
            selection = [pendingInlineRenameURL]
        }
        browser.displayPath(snapshot.directoryURL.path)
        browser.displayRows(snapshot.items.map(BrowserFileRow.init), selecting: selection)
        if let pendingInlineRenameURL,
           snapshot.items.contains(where: { $0.url == pendingInlineRenameURL }) {
            self.pendingInlineRenameURL = nil
            if viewMode != .details { setViewMode(.details) }
            browser.beginRenaming(pendingInlineRenameURL)
        }
        onTitleChange?(displayTitle)
        let label = "\(snapshot.items.count) \(snapshot.items.count == 1 ? "item" : "items")"
        browser.showStatus(snapshot.issues.isEmpty ? label : "\(label); \(snapshot.issues.count) item(s) could not be read.")
        if origin != .refresh || directoryMonitor == nil {
            startMonitoring(snapshot.directoryURL)
        }
    }

    private func open(_ row: BrowserFileRow) {
        if row.isNavigable { requestDirectory(row.url, origin: .newLocation); return }
        if !NSWorkspace.shared.open(row.url) { browser.showStatus("Unable to open \(row.name) with its default application.") }
    }

    private var selectedRows: [BrowserFileRow] {
        currentSnapshot?.items
            .filter { selection.contains($0.url) }
            .map(BrowserFileRow.init) ?? []
    }

    private func openSelection() {
        let rows = selectedRows
        if rows.count == 1, let row = rows.first {
            open(row)
            return
        }
        for row in rows {
            if row.isNavigable {
                onOpenLocationInNewTab?(row.url)
            } else if !NSWorkspace.shared.open(row.url) {
                browser.showStatus("Unable to open \(row.name) with its default application.")
            }
        }
    }

    private func openSelection(with applicationURL: URL) {
        let urls = selectedRows.map(\.url)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            do {
                _ = try await NSWorkspace.shared.open(
                    urls,
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } catch {
                self?.browser.showStatus(
                    "Unable to open with \(applicationURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    private func copyPaths(_ urls: [URL]) {
        let paths = urls.map(\.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.setString(paths, forType: .string)
        let noun = urls.count == 1 ? "path" : "paths"
        browser.showStatus("Copied \(urls.count) \(noun).")
    }

    private func favoriteURLToAdd() -> URL? {
        guard selection.count == 1, let row = selectedRows.first, row.isNavigable else { return nil }
        guard canAddFavorite?(row.url) == true else { return nil }
        return row.url
    }

    private func makeContextMenuState() -> BrowserContextMenuState {
        let rows = selectedRows
        return BrowserContextMenuState(
            hasSelection: !rows.isEmpty,
            hasNavigableSelection: rows.contains(where: \.isNavigable),
            isSingleSelection: rows.count == 1,
            canPaste: canPerformFileCommand(.paste),
            canAddToFavorites: favoriteURLToAdd() != nil,
            openWithApplications: openWithApplications(for: rows)
        )
    }

    private func openWithApplications(for rows: [BrowserFileRow]) -> [BrowserOpenWithApplication] {
        guard rows.count == 1, let row = rows.first, !row.isNavigable else { return [] }
        return WorkspaceOpenWith.applications(for: row.url)
    }

    private func createNewFolder(in parentURL: URL) {
        let parent = parentURL.standardizedFileURL
        submit(.createFolder(at: parent, name: "New Folder", conflictPolicy: .keepBoth)) { [weak self] result in
            guard let self,
                  let destination = result.items.first(where: { $0.status == .completed })?.destination else { return }
            self.loadSidebarChildren(of: parent)
            guard self.currentDirectoryURL == parent else { return }
            self.selection = [destination]
            self.pendingInlineRenameURL = destination
        }
    }

    private func url(forSubmittedPath path: String) -> URL {
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        let expandedPath = (path as NSString).expandingTildeInPath
        return expandedPath.hasPrefix("/")
            ? URL(fileURLWithPath: expandedPath).standardizedFileURL
            : homeURL.appendingPathComponent(expandedPath).standardizedFileURL
    }

    private func filterCurrentDirectory(matching text: String) {
        guard let currentSnapshot else {
            browser.showStatus("Wait for the folder to finish loading before searching.")
            return
        }
        searchCoordinator.search(
            snapshot: currentSnapshot,
            text: text,
            includesHiddenFiles: showsHiddenFiles
        )
    }

    private func displaySearchResults(_ items: [FileItem], query: String, isComplete: Bool) {
        selection.formIntersection(Set(items.map(\.url)))
        browser.displayRows(items.map(BrowserFileRow.init), selecting: selection)
        let noun = items.count == 1 ? "match" : "matches"
        if isComplete {
            browser.showStatus("\(items.count) \(noun) for “\(query)”.")
        } else {
            browser.showStatus("Searching for “\(query)”… \(items.count) \(noun) so far.")
        }
    }

    private func restoreUnfilteredSnapshot() {
        searchCoordinator.cancel()
        guard let currentSnapshot else { return }
        selection.formIntersection(Set(currentSnapshot.items.map(\.url)))
        browser.displayRows(currentSnapshot.items.map(BrowserFileRow.init), selecting: selection)
        let label = "\(currentSnapshot.items.count) \(currentSnapshot.items.count == 1 ? "item" : "items")"
        browser.showStatus(label)
    }

    private var directoryLoadOptions: DirectoryLoadOptions {
        DirectoryLoadOptions(
            showsHiddenFiles: showsHiddenFiles,
            sortDescriptor: sortDescriptor.fileSortDescriptor
        )
    }

    private var sidebarLoadOptions: DirectoryLoadOptions {
        DirectoryLoadOptions(showsHiddenFiles: showsHiddenFiles)
    }

    private func startMonitoring(_ directoryURL: URL) {
        stopMonitoring()
        monitorGeneration &+= 1
        let generation = monitorGeneration
        let monitoredURL = directoryURL.standardizedFileURL
        let monitor = DirectoryChangeMonitor()
        directoryMonitor = monitor
        monitorTask = Task { [weak self] in
            do {
                let invalidations = try await monitor.invalidations(at: monitoredURL)
                for await invalidation in invalidations {
                    guard !Task.isCancelled, let self,
                          generation == self.monitorGeneration,
                          self.currentDirectoryURL == invalidation.directoryURL else { return }
                    try await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, generation == self.monitorGeneration,
                          self.currentDirectoryURL == invalidation.directoryURL else { return }
                    self.requestDirectory(invalidation.directoryURL, origin: .refresh)
                }
            } catch is CancellationError {
            } catch {
                // Monitoring is an enhancement; browsing remains usable when a
                // provider cannot watch a particular directory.
            }
        }
    }

    private func stopMonitoring() {
        monitorGeneration &+= 1
        monitorTask?.cancel()
        monitorTask = nil
        let monitor = directoryMonitor
        directoryMonitor = nil
        if let monitor { Task { await monitor.stop() } }
    }

    private func writeClipboard(intent: FileClipboardIntent) {
        do {
            switch intent {
            case .copy: try clipboard.copy(Array(selection))
            case .cut: try clipboard.cut(Array(selection))
            }
            browser.showStatus("\(selection.count) \(selection.count == 1 ? "item" : "items") \(intent == .copy ? "copied" : "cut").")
        } catch {
            browser.showStatus(error.localizedDescription)
        }
    }

    @objc private func fileClipboardDidChange(_ notification: Notification) {
        synchronizeCutPresentation()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        synchronizeCutPresentation()
    }

    private func synchronizeCutPresentation() {
        guard let contents = clipboard.read(), contents.intent == .cut else {
            browser.setCutURLs([])
            return
        }
        browser.setCutURLs(Set(contents.urls))
    }

    private func pasteClipboardContents() {
        guard let currentDirectoryURL, let contents = clipboard.read() else { return }
        let operation: FileOperation
        switch contents.intent {
        case .copy:
            operation = .copy(sources: contents.urls, to: currentDirectoryURL, conflictPolicy: .ask)
        case .cut:
            operation = .move(sources: contents.urls, to: currentDirectoryURL, conflictPolicy: .ask)
        }
        submit(operation)
    }

    private func submit(
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

    private func accept(_ drop: BrowserFileDrop) -> Bool {
        guard let destination = drop.destinationURL ?? currentDirectoryURL else { return false }
        guard !drop.urls.contains(where: { source in
            let sourcePath = source.standardizedFileURL.path
            let destinationPath = destination.standardizedFileURL.path
            return destinationPath.hasPrefix(sourcePath + "/")
        }) else {
            browser.showStatus("Cannot drop a folder into one of its descendants.")
            return false
        }
        let operation: FileOperation
        switch drop.intent {
        case .copy:
            operation = .copy(sources: drop.urls, to: destination, conflictPolicy: .ask)
        case .move:
            operation = .move(sources: drop.urls, to: destination, conflictPolicy: .ask)
        }
        submit(operation)
        return true
    }

    private func accept(_ drop: BrowserPromisedFileDrop) -> Bool {
        guard let destination = drop.destinationURL ?? currentDirectoryURL else { return false }
        guard !drop.receivers.isEmpty else { return false }
        let staging: URL
        do {
            staging = try FilePromiseDropCoordinator.makeStagingDirectory()
        } catch {
            browser.showStatus(error.localizedDescription)
            return false
        }

        let receivers = drop.receivers
        let queue = filePromiseQueue
        browser.showStatus("Receiving dropped files…")
        Task { [weak self] in
            do {
                let urls = try await FilePromiseDropCoordinator.receivePromisedFiles(
                    receivers,
                    into: staging,
                    operationQueue: queue
                )
                guard let self else {
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                guard !urls.isEmpty else {
                    self.browser.showStatus(FilePromiseDropError.empty.localizedDescription)
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                self.submit(
                    .move(sources: urls, to: destination, conflictPolicy: .ask),
                    finished: { try? FileManager.default.removeItem(at: staging) }
                )
            } catch {
                self?.browser.showStatus(error.localizedDescription)
                try? FileManager.default.removeItem(at: staging)
            }
        }
        return true
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

    private func toggleQuickLook() {
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

private extension BrowserSortDescriptor {
    var fileSortDescriptor: FileSortDescriptor {
        let mappedField: FileSortField = switch field {
        case .name: .name
        case .size: .size
        case .modified: .modificationDate
        case .kind: .kind
        }
        return FileSortDescriptor(
            field: mappedField,
            direction: ascending ? .ascending : .descending,
            directoriesFirst: true
        )
    }
}
