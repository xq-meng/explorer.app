import AppKit
import ExplorerBrowsing
import ExplorerOperations
import ExplorerUI
@preconcurrency import QuickLookUI

@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let tabViewController = ExplorerTabsViewController()
    private let settings = ExplorerSettingsStore()
    private let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    private let operationQueue = FileOperationQueue()
    private let clipboard = FileClipboardService()
    private let mountedVolumeService = MountedVolumeService()
    private var sessions: [ExplorerTabController] = []
    private var mountedVolumes: [MountedVolumeMetadata] = []
    private lazy var navigationLocations = buildNavigationLocations()
    private var operationEventTask: Task<Void, Never>?
    private var volumeLoadTask: Task<Void, Never>?
    private var didStartVolumeLoading = false
    private var operationHistory = FileOperationHistory()
    private var historyTask: Task<Void, Never>?
    private var didOpenInitialTab = false
    private var operationSnapshots: [UUID: FileOperationQueueSnapshot] = [:]
    private var operationProgress: [UUID: FileOperationProgress] = [:]
    private var operationOrder: [UUID] = []

    init() {
        let defaultFrame = NSRect(x: 0, y: 0, width: 1280, height: 760)
        let storedFrame = settings.windowFrame
        let frame: NSRect
        if let storedFrame, storedFrame.width >= 900, storedFrame.height >= 560 {
            frame = storedFrame
        } else {
            frame = defaultFrame
        }
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Explorer"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 560)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = tabViewController
        if storedFrame == nil { window.center() }
        super.init(window: window)
        window.delegate = self
        window.addTitlebarAccessoryViewController(tabViewController.makeTitlebarAccessoryViewController())
        updateTitlebarTabsWidth()
        tabViewController.onSelectionChange = { [weak self] in
            self?.sessions.forEach { $0.closeQuickLook() }
            self?.updateWindowTitle()
        }
        tabViewController.onNewTab = { [weak self] in self?.newTab() }
        tabViewController.onCloseTab = { [weak self] in self?.closeCurrentTab() }
        tabViewController.onCancelOperation = { [weak self] in self?.cancelCurrentOperation() }
        observeOperationEvents()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        openInitialTabIfNeeded()
        startVolumeLoading()
    }

    func perform(_ command: BrowserNavigationCommand) { currentSession?.perform(command) }

    func newTab(at location: BrowserLocation? = nil) {
        let startingLocation = location ?? currentSession?.currentLocation ?? .computer
        let initialViewMode = currentSession?.viewMode ?? restoredViewMode
        let initialSortDescriptor = currentSession?.sortDescriptor ?? .nameAscending
        let session = ExplorerTabController(
            homeURL: homeURL,
            sidebarLocations: navigationLocations.sidebar,
            initialViewMode: initialViewMode,
            initialSortDescriptor: initialSortDescriptor,
            initialShowsPreview: restoredPreviewVisibility,
            initialShowsHiddenFiles: settings.showsHiddenFiles,
            sidebarWidth: settings.sidebarWidth,
            homePageModel: navigationLocations.homePage,
            operationQueue: operationQueue,
            clipboard: clipboard
        )
        let item = NSTabViewItem(viewController: session)
        item.label = "Loading…"
        session.onEvent = { [weak self, weak item, weak session] event in
            guard let self, let session else { return }
            self.handle(event, from: session, item: item)
        }
        session.setOccupiedDirectoryURLs(navigationLocations.occupiedDirectoryURLs)
        tabViewController.addTabViewItem(item)
        tabViewController.selectedTabViewItemIndex = tabViewController.tabViewItems.count - 1
        sessions.append(session)
        session.start(at: startingLocation)
    }

    private func handle(
        _ event: ExplorerTabEvent,
        from session: ExplorerTabController,
        item: NSTabViewItem?
    ) {
        switch event {
        case let .titleChange(title):
            item?.label = title
            tabViewController.refreshTabs()
            guard currentSession === session else { return }
            window?.title = "Explorer — \(title)"
        case let .viewModeChange(mode):
            settings.viewMode = mode
        case let .previewVisibilityChange(isVisible):
            settings.showsPreview = isVisible
        case let .sidebarWidthChange(width):
            settings.sidebarWidth = width
        case let .operationCompleted(operation, result):
            recordUndoPlan(for: operation, result: result)
        case let .openLocationInNewTab(location):
            newTab(at: location)
        case let .removeFavorite(url):
            removeFavorite(url)
        case let .addFavorite(url):
            addFavorite(url)
        case .homePageRefresh:
            reloadVolumes()
        }
    }

    func closeCurrentTab() {
        guard let item = selectedTabItem, let session = item.viewController as? ExplorerTabController else { return }
        guard tabViewController.tabViewItems.count > 1 else { window?.performClose(self); return }
        session.cancelLoading()
        sessions.removeAll { $0 === session }
        tabViewController.removeTabViewItem(item)
        updateWindowTitle()
    }

    func setViewMode(_ mode: BrowserViewMode) { currentSession?.setViewMode(mode) }
    var canChangeViewMode: Bool { currentSession?.canChangeViewMode ?? false }
    func togglePreview() { currentSession?.togglePreview() }
    func setShowsHiddenFiles(_ isVisible: Bool) {
        settings.showsHiddenFiles = isVisible
        sessions.forEach { $0.setShowsHiddenFiles(isVisible) }
    }
    func setPreviewVisible(_ isVisible: Bool) {
        settings.showsPreview = isVisible
        sessions.forEach { $0.setPreviewVisible(isVisible) }
    }
    var isPreviewVisible: Bool { currentSession?.showsPreview ?? restoredPreviewVisibility }
    var canUndo: Bool { historyTask == nil && operationHistory.canUndo }
    var canRedo: Bool { historyTask == nil && operationHistory.canRedo }
    var undoActionName: String? { operationHistory.undoActionName }
    var redoActionName: String? { operationHistory.redoActionName }
    var canAddCurrentFolderToFavorites: Bool {
        guard let url = currentSession?.currentLocation?.directoryURL else { return false }
        return canAddFavorite(url)
    }
    func performFileCommand(_ command: BrowserFileCommand) { currentSession?.performFileCommand(command) }
    func canPerformFileCommand(_ command: BrowserFileCommand) -> Bool { currentSession?.canPerformFileCommand(command) ?? false }

    func undoLastOperation() {
        guard historyTask == nil, let plan = operationHistory.take(.undo) else { return }
        performHistory(plan, direction: .undo)
    }

    func redoLastOperation() {
        guard historyTask == nil, let plan = operationHistory.take(.redo) else { return }
        performHistory(plan, direction: .redo)
    }

    func addCurrentFolderToFavorites() {
        guard let url = currentSession?.currentLocation?.directoryURL else { return }
        addFavorite(url)
    }

    func windowDidBecomeKey(_ notification: Notification) { updateWindowTitle() }
    func windowDidResize(_ notification: Notification) { updateTitlebarTabsWidth() }
    func windowDidEnterFullScreen(_ notification: Notification) { updateTitlebarTabsWidth() }
    func windowDidExitFullScreen(_ notification: Notification) { updateTitlebarTabsWidth() }
    func windowDidEndLiveResize(_ notification: Notification) { persistWindowState() }
    func windowWillClose(_ notification: Notification) {
        persistWindowState()
        sessions.forEach { $0.cancelLoading() }
        operationEventTask?.cancel()
        volumeLoadTask?.cancel()
        historyTask?.cancel()
        onClose?()
    }

    private var selectedTabItem: NSTabViewItem? {
        let index = tabViewController.selectedTabViewItemIndex
        guard tabViewController.tabViewItems.indices.contains(index) else { return nil }
        return tabViewController.tabViewItems[index]
    }
    private var currentSession: ExplorerTabController? { selectedTabItem?.viewController as? ExplorerTabController }
    private var restoredViewMode: BrowserViewMode { settings.viewMode }
    private var restoredPreviewVisibility: Bool { settings.showsPreview }

    private func updateTitlebarTabsWidth() {
        guard let window else { return }
        let buttonFrames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> NSRect? in
            guard let button = window.standardWindowButton(type), let superview = button.superview else { return nil }
            return superview.convert(button.frame, to: nil)
        }
        let controlsFrame = buttonFrames.reduce(NSRect.null) { $0.union($1) }
        let controlsWidth: CGFloat
        if controlsFrame.isNull {
            controlsWidth = 80
        } else if window.windowTitlebarLayoutDirection == .rightToLeft {
            controlsWidth = window.frame.width - controlsFrame.minX
        } else {
            controlsWidth = controlsFrame.maxX
        }
        tabViewController.setTitlebarAccessoryWidth(max(220, window.frame.width - controlsWidth - 12))
    }

    private func buildNavigationLocations() -> ExplorerNavigationLocations {
        ExplorerNavigationLocationBuilder.build(
            homeURL: homeURL,
            favoriteURLs: settings.favoriteURLs,
            mountedVolumes: mountedVolumes,
            isDirectory: Self.isDirectory
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func addFavorite(_ url: URL) {
        let url = url.standardizedFileURL
        guard canAddFavorite(url) else { return }
        settings.addFavorite(url)
        refreshSidebarLocations()
        currentSession?.showStatus("Added \(url.lastPathComponent) to Favorites.")
    }

    private func canAddFavorite(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return !navigationLocations.contains(url)
    }

    private func removeFavorite(_ url: URL) {
        settings.removeFavorite(url)
        refreshSidebarLocations()
        currentSession?.showStatus("Removed \(url.lastPathComponent) from Favorites.")
    }

    private func refreshSidebarLocations() {
        navigationLocations = buildNavigationLocations()
        sessions.forEach {
            $0.updateSidebarLocations(navigationLocations.sidebar)
            $0.updateHomePage(navigationLocations.homePage)
            $0.setOccupiedDirectoryURLs(navigationLocations.occupiedDirectoryURLs)
        }
    }

    /// A new window always starts at My Computer.
    private func openInitialTabIfNeeded() {
        guard !didOpenInitialTab else { return }
        didOpenInitialTab = true
        newTab(at: .computer)
    }

    private func observeOperationEvents() {
        let events = operationQueue.events
        operationEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.sessions.forEach { $0.handleOperationEvent(event) }
                self.track(event)
            }
        }
    }

    private func track(_ event: FileOperationQueueEvent) {
        switch event {
        case let .stateChanged(snapshot):
            if operationSnapshots[snapshot.id] == nil {
                operationOrder.append(snapshot.id)
            }
            operationSnapshots[snapshot.id] = snapshot
            switch snapshot.state {
            case .completed, .failed, .cancelled:
                operationProgress[snapshot.id] = nil
            case .queued, .running:
                break
            }
        case let .progress(progress):
            operationProgress[progress.id] = progress.progress
        }
        updateOperationActivity()
        pruneFinishedOperations()
    }

    private func updateOperationActivity() {
        let queued = operationOrder.compactMap { operationSnapshots[$0] }.filter { $0.state == .queued }
        let running = operationOrder.compactMap { operationSnapshots[$0] }.first { $0.state == .running }
        guard running != nil || !queued.isEmpty else {
            tabViewController.setOperationActivity(nil)
            return
        }
        tabViewController.setOperationActivity(activity(running: running, queuedCount: queued.count))
    }

    private func activity(
        running: FileOperationQueueSnapshot?,
        queuedCount: Int
    ) -> BrowserOperationActivity {
        if let running {
            let progress = operationProgress[running.id]
            let completed = progress?.completedItems ?? 0
            let total = progress?.totalItems ?? max(1, itemCount(for: running.operation))
            let current = progress?.currentItem?.lastPathComponent
            let displayedItem = completed < total ? completed + 1 : total
            let title = "\(progressTitle(for: running.operation.kind)) \(displayedItem) of \(total)"
            return BrowserOperationActivity(
                title: queuedCount > 0 ? "\(title) • \(queuedCount) waiting" : title,
                detail: progressDetail(progress: progress, fallbackName: current, kind: running.operation.kind),
                fractionCompleted: progress?.fractionCompleted ?? 0,
                queuedCount: queuedCount
            )
        }
        let queued = operationOrder.compactMap { operationSnapshots[$0] }.first { $0.state == .queued }
        return BrowserOperationActivity(
            title: queued.map { "\(progressTitle(for: $0.operation.kind)) waiting" } ?? "Operation waiting",
            detail: queued.map { waitingDetail(for: $0.operation) } ?? "Waiting to start.",
            fractionCompleted: 0,
            queuedCount: queuedCount
        )
    }

    private func progressTitle(for kind: FileOperationKind) -> String {
        kind.progressiveName
    }

    private func progressDetail(
        progress: FileOperationProgress?,
        fallbackName: String?,
        kind: FileOperationKind
    ) -> String {
        let name = fallbackName ?? progress?.currentItem?.lastPathComponent ?? progressTitle(for: kind)
        if let progress, let totalBytes = progress.totalBytes, totalBytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
            let completed = formatter.string(fromByteCount: progress.completedBytes)
            let total = formatter.string(fromByteCount: totalBytes)
            return "\(name) — \(completed) of \(total)"
        }
        return name
    }

    private func waitingDetail(for operation: FileOperation) -> String {
        switch operation {
        case .createFolder(let request):
            return request.name
        case .rename(let request):
            return request.name
        case .copy(let request), .move(let request):
            return request.sources.count == 1
                ? request.sources[0].lastPathComponent
                : "\(request.sources.count) items"
        case .duplicate(let request):
            return request.source.lastPathComponent
        case .trash(let request), .delete(let request):
            return request.sources.count == 1
                ? request.sources[0].lastPathComponent
                : "\(request.sources.count) items"
        }
    }

    private func itemCount(for operation: FileOperation) -> Int {
        switch operation {
        case .copy(let request), .move(let request): request.sources.count
        case .trash(let request), .delete(let request): request.sources.count
        case .createFolder, .rename, .duplicate: 1
        }
    }

    private func pruneFinishedOperations() {
        let finishedIDs = operationSnapshots.compactMap { id, snapshot -> UUID? in
            switch snapshot.state {
            case .completed, .failed, .cancelled: id
            case .queued, .running: nil
            }
        }
        for id in finishedIDs {
            operationSnapshots[id] = nil
            operationProgress[id] = nil
            operationOrder.removeAll { $0 == id }
        }
    }

    private func cancelCurrentOperation() {
        let target = operationOrder.compactMap { operationSnapshots[$0] }.first {
            $0.state == .running || $0.state == .queued
        }
        guard let target else { return }
        let queue = operationQueue
        Task { _ = await queue.cancel(target.id) }
    }

    private func recordUndoPlan(for operation: FileOperation, result: FileOperationResult) {
        guard let plan = FileOperationUndoPlanner.plan(for: operation, result: result) else { return }
        operationHistory.record(plan)
    }

    private func performHistory(_ plan: FileOperationUndoPlan, direction: FileOperationHistoryDirection) {
        let operations = direction == .undo ? plan.undoOperations : plan.redoOperations
        currentSession?.showStatus("\(direction.statusVerb) \(plan.actionName)…")
        let queue = operationQueue
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                for operation in operations {
                    try Task.checkCancellation()
                    let id = await queue.submit(operation)
                    _ = try await queue.result(for: id)
                }
                guard !Task.isCancelled else { throw CancellationError() }
                self.operationHistory.complete(plan, direction: direction)
                self.sessions.forEach { $0.refreshContents() }
                self.currentSession?.showStatus("\(direction.completedVerb) \(plan.actionName).")
            } catch {
                self.operationHistory.restore(plan, direction: direction)
                self.currentSession?.showStatus("Unable to \(direction.commandVerb) \(plan.actionName): \(error.localizedDescription)")
            }
            self.historyTask = nil
        }
    }

    private func startVolumeLoading() {
        guard !didStartVolumeLoading else { return }
        didStartVolumeLoading = true
        reloadVolumes()
    }

    private func reloadVolumes() {
        volumeLoadTask?.cancel()
        let service = mountedVolumeService
        volumeLoadTask = Task { [weak self] in
            do {
                let volumes = try await service.mountedVolumes()
                guard !Task.isCancelled, let self else { return }
                self.mountedVolumes = volumes
                self.refreshSidebarLocations()
            } catch is CancellationError {
            } catch {
                // Mounted volumes are supplemental navigation locations.
            }
        }
    }

    private func updateWindowTitle() { if let session = currentSession { window?.title = "Explorer — \(session.displayTitle)" } }
    private func persistWindowState() { if let window { settings.windowFrame = window.frame } }
}

extension ExplorerWindowController {
    @objc nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { currentSession?.canAcceptQuickLookControl == true }
    }

    @objc nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { currentSession?.beginQuickLookControl(panel) }
    }

    @objc nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}
