import AppKit
import ExplorerBrowsing
import ExplorerOperations
import ExplorerUI

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
    private var mountedVolumeLocations: [BrowserSidebarLocation] = []
    private var operationEventTask: Task<Void, Never>?
    private var volumeLoadTask: Task<Void, Never>?
    private var didStartVolumeLoading = false
    private var operationHistory = FileOperationHistory()
    private var historyTask: Task<Void, Never>?
    private var didRestoreSession = false
    private var isRestoringSession = false
    private var operationSnapshots: [UUID: FileOperationQueueSnapshot] = [:]
    private var operationProgress: [UUID: FileOperationProgress] = [:]
    private var operationOrder: [UUID] = []

    init() {
        let defaultFrame = NSRect(x: 0, y: 0, width: 1280, height: 760)
        let storedFrame = settings.windowFrame
        let frame = (storedFrame?.width ?? 0) >= 900 && (storedFrame?.height ?? 0) >= 560 ? storedFrame! : defaultFrame
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
            self?.persistSessionState()
        }
        tabViewController.onNewTab = { [weak self] in self?.newTab() }
        tabViewController.onCloseTab = { [weak self] in self?.closeCurrentTab() }
        tabViewController.onTabsReordered = { [weak self] in self?.persistSessionState() }
        tabViewController.onCancelOperation = { [weak self] in self?.cancelCurrentOperation() }
        observeOperationEvents()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        restoreSessionIfNeeded()
        startVolumeLoading()
    }

    func perform(_ command: BrowserNavigationCommand) { currentSession?.perform(command) }

    func newTab(at url: URL? = nil, restoring state: ExplorerSettingsStore.TabState? = nil) {
        let startingURL = state?.url ?? url ?? currentSession?.currentDirectoryURL ?? homeURL
        let initialViewMode = state?.viewMode ?? currentSession?.viewMode ?? restoredViewMode
        let initialSortDescriptor = state?.sortDescriptor ?? currentSession?.sortDescriptor ?? .nameAscending
        let session = ExplorerTabController(
            homeURL: homeURL,
            sidebarLocations: allSidebarLocations,
            initialViewMode: initialViewMode,
            initialSortDescriptor: initialSortDescriptor,
            initialShowsPreview: restoredPreviewVisibility,
            initialShowsHiddenFiles: settings.showsHiddenFiles,
            sidebarWidth: settings.sidebarWidth,
            operationQueue: operationQueue,
            clipboard: clipboard
        )
        let item = NSTabViewItem(viewController: session)
        item.label = "Loading…"
        session.onTitleChange = { [weak self, weak item, weak session] title in
            item?.label = title
            self?.tabViewController.refreshTabs()
            guard self?.currentSession === session else { return }
            self?.window?.title = "Explorer — \(title)"
            self?.persistSessionState()
        }
        session.onViewModeChange = { [weak self] mode in
            self?.settings.viewMode = mode
            self?.persistSessionState()
        }
        session.onSortChange = { [weak self] _ in self?.persistSessionState() }
        session.onPreviewVisibilityChange = { [weak self] isVisible in
            self?.settings.showsPreview = isVisible
        }
        session.onSidebarWidthChange = { [weak self] width in
            self?.settings.sidebarWidth = width
        }
        session.onOperationCompleted = { [weak self] operation, result in
            self?.recordUndoPlan(for: operation, result: result)
        }
        session.onOpenLocationInNewTab = { [weak self] url in self?.newTab(at: url) }
        session.onRemoveFavorite = { [weak self] url in self?.removeFavorite(url) }
        tabViewController.addTabViewItem(item)
        tabViewController.selectedTabViewItemIndex = tabViewController.tabViewItems.count - 1
        sessions.append(session)
        session.start(at: startingURL)
        persistSessionState()
    }

    func closeCurrentTab() {
        guard let item = selectedTabItem, let session = item.viewController as? ExplorerTabController else { return }
        guard tabViewController.tabViewItems.count > 1 else { window?.performClose(self); return }
        session.cancelLoading()
        sessions.removeAll { $0 === session }
        tabViewController.removeTabViewItem(item)
        updateWindowTitle()
        persistSessionState()
    }

    func setViewMode(_ mode: BrowserViewMode) { currentSession?.setViewMode(mode) }
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
        guard let url = currentSession?.currentDirectoryURL else { return false }
        return !allSidebarLocations.contains(where: { $0.url == url })
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
        guard let url = currentSession?.currentDirectoryURL, canAddCurrentFolderToFavorites else { return }
        settings.addFavorite(url)
        refreshSidebarLocations()
        currentSession?.showStatus("Added \(url.lastPathComponent) to Favorites.")
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
        persistSessionState()
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

    private var standardSidebarLocations: [BrowserSidebarLocation] {
        var locations = [BrowserSidebarLocation(title: "Home", url: homeURL, kind: .favorite)]
        for name in ["Desktop", "Documents", "Downloads"] {
            let url = homeURL.appendingPathComponent(name, isDirectory: true)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                locations.append(BrowserSidebarLocation(title: name, url: url, kind: .favorite))
            }
        }
        if let applicationsURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first,
           (try? applicationsURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            locations.append(BrowserSidebarLocation(title: "Applications", url: applicationsURL, kind: .favorite))
        }
        return locations
    }

    private var customSidebarLocations: [BrowserSidebarLocation] {
        let standardURLs = Set(standardSidebarLocations.map(\.url))
        var seen = standardURLs
        return settings.favoriteURLs.compactMap { url in
            guard seen.insert(url).inserted else { return nil }
            let title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return BrowserSidebarLocation(title: title, url: url, kind: .favorite, isRemovable: true)
        }
    }

    private var allSidebarLocations: [BrowserSidebarLocation] {
        var locations = standardSidebarLocations + customSidebarLocations
        var seenURLs = Set(locations.map(\.url))
        for volume in mountedVolumeLocations where seenURLs.insert(volume.url).inserted {
            locations.append(volume)
        }
        return locations
    }

    private func removeFavorite(_ url: URL) {
        settings.removeFavorite(url)
        refreshSidebarLocations()
        currentSession?.showStatus("Removed \(url.lastPathComponent) from Favorites.")
    }

    private func refreshSidebarLocations() {
        let locations = allSidebarLocations
        sessions.forEach { $0.updateSidebarLocations(locations) }
    }

    private func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        isRestoringSession = true
        let restored = settings.restoredTabSession()
        if restored.tabs.isEmpty {
            newTab(at: homeURL)
        } else {
            restored.tabs.forEach { newTab(restoring: $0) }
            tabViewController.selectedTabViewItemIndex = min(max(0, restored.selectedIndex), sessions.count - 1)
        }
        isRestoringSession = false
        persistSessionState()
    }

    private func persistSessionState() {
        guard !isRestoringSession else { return }
        settings.saveTabSession(
            tabs: tabViewController.tabViewItems.compactMap {
                guard let session = $0.viewController as? ExplorerTabController,
                      let url = session.currentDirectoryURL else { return nil }
                return ExplorerSettingsStore.TabState(
                    url: url,
                    viewMode: session.viewMode,
                    sortDescriptor: session.sortDescriptor
                )
            },
            selectedIndex: tabViewController.selectedTabViewItemIndex
        )
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
        switch kind {
        case .createFolder: "Creating folder"
        case .rename: "Renaming"
        case .copy: "Copying"
        case .move: "Moving"
        case .duplicate: "Duplicating"
        case .trash: "Moving to Trash"
        }
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
        case .trash(let request):
            return request.sources.count == 1
                ? request.sources[0].lastPathComponent
                : "\(request.sources.count) items"
        }
    }

    private func itemCount(for operation: FileOperation) -> Int {
        switch operation {
        case .copy(let request), .move(let request): request.sources.count
        case .trash(let request): request.sources.count
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
        let service = mountedVolumeService
        volumeLoadTask = Task { [weak self] in
            do {
                let volumes = try await service.mountedVolumes()
                guard !Task.isCancelled, let self else { return }
                let homeURL = self.homeURL
                self.mountedVolumeLocations = volumes.compactMap { volume in
                    guard volume.url.standardizedFileURL != homeURL else { return nil }
                    return BrowserSidebarLocation(title: volume.displayName, url: volume.url, kind: .volume)
                }
                let locations = self.allSidebarLocations
                self.sessions.forEach { $0.updateSidebarLocations(locations) }
            } catch is CancellationError {
            } catch {
                // Mounted volumes are supplemental navigation locations.
            }
        }
    }

    private func updateWindowTitle() { if let session = currentSession { window?.title = "Explorer — \(session.displayTitle)" } }
    private func persistWindowState() { if let window { settings.windowFrame = window.frame } }
}
