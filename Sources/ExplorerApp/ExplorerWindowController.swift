import AppKit
import ExplorerBrowsing
import ExplorerOperations
import ExplorerUI
@preconcurrency import QuickLookUI

struct ExplorerWindowState {
    let location: BrowserLocation
    let viewMode: BrowserViewMode
    let sortDescriptor: BrowserSortDescriptor
}

@MainActor
final class ExplorerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onRequestNewTab: ((ExplorerWindowState) -> Void)?
    var onNavigationLocationsChange: (() -> Void)?

    private let settings: ExplorerSettingsStore
    private let homeURL: URL
    private let operationQueue: FileOperationQueue
    private let mountedVolumeService: MountedVolumeService
    private let session: ExplorerTabController
    private let contentController: ExplorerWindowContentViewController
    private var mountedVolumes: [MountedVolumeMetadata] = []
    private var navigationLocations: ExplorerNavigationLocations
    private var operationEventTask: Task<Void, Never>?
    private var volumeLoadTask: Task<Void, Never>?
    private var didStartVolumeLoading = false
    private var operationHistory = FileOperationHistory()
    private var historyTask: Task<Void, Never>?
    private var didStartSession = false
    private let initialState: ExplorerWindowState
    private var operationSnapshots: [UUID: FileOperationQueueSnapshot] = [:]
    private var operationProgress: [UUID: FileOperationProgress] = [:]
    private var operationOrder: [UUID] = []
    private var isPresentingCloseConfirmation = false
    private var allowsCloseWithActiveOperations = false
    private var closeCancellationTask: Task<Void, Never>?

    init(
        initialState: ExplorerWindowState? = nil,
        recoveryJournal: FileOperationRecoveryJournal = FileOperationRecoveryJournal(),
        operationQueue injectedOperationQueue: FileOperationQueue? = nil
    ) {
        let settings = ExplorerSettingsStore()
        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let operationQueue = injectedOperationQueue
            ?? FileOperationQueue(engine: FileOperationEngine(recoveryJournal: recoveryJournal))
        let clipboard = FileClipboardService()
        let mountedVolumeService = MountedVolumeService()
        let resolvedState = initialState ?? ExplorerWindowState(
            location: .computer,
            viewMode: settings.viewMode,
            sortDescriptor: .nameAscending
        )
        let navigationLocations = ExplorerNavigationLocationBuilder.build(
            homeURL: homeURL,
            favoriteURLs: settings.favoriteURLs,
            mountedVolumes: [],
            isDirectory: Self.isDirectory
        )
        let session = ExplorerTabController(
            homeURL: homeURL,
            sidebarLocations: navigationLocations.sidebar,
            initialViewMode: resolvedState.viewMode,
            initialSortDescriptor: resolvedState.sortDescriptor,
            initialShowsPreview: settings.showsPreview,
            initialShowsHiddenFiles: settings.showsHiddenFiles,
            sidebarWidth: settings.sidebarWidth,
            homePageModel: navigationLocations.homePage,
            operationQueue: operationQueue,
            clipboard: clipboard
        )
        let contentController = ExplorerWindowContentViewController(browserController: session)

        self.settings = settings
        self.homeURL = homeURL
        self.operationQueue = operationQueue
        self.mountedVolumeService = mountedVolumeService
        self.session = session
        self.contentController = contentController
        self.navigationLocations = navigationLocations
        self.initialState = resolvedState

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
        window.tabbingIdentifier = "app.explorer.browser"
        window.tabbingMode = .preferred
        window.tab.title = "Loading…"
        window.tab.toolTip = "Loading…"
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = contentController
        if storedFrame == nil { window.center() }
        super.init(window: window)
        window.delegate = self
        contentController.onCancelOperation = { [weak self] in self?.cancelCurrentOperation() }
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.setOccupiedDirectoryURLs(navigationLocations.occupiedDirectoryURLs)
        observeOperationEvents()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startSessionIfNeeded()
        startVolumeLoading()
    }

    func perform(_ command: BrowserNavigationCommand) { session.perform(command) }

    var stateForNewTab: ExplorerWindowState {
        ExplorerWindowState(
            location: session.currentLocation ?? .computer,
            viewMode: session.viewMode,
            sortDescriptor: session.sortDescriptor
        )
    }

    func stateForNewTab(at location: BrowserLocation) -> ExplorerWindowState {
        ExplorerWindowState(
            location: location,
            viewMode: session.viewMode,
            sortDescriptor: session.sortDescriptor
        )
    }

    @IBAction override func newWindowForTab(_ sender: Any?) {
        onRequestNewTab?(stateForNewTab)
    }

    private func handle(_ event: ExplorerTabEvent) {
        switch event {
        case let .titleChange(title):
            updateWindowTitle(title)
        case let .viewModeChange(mode):
            settings.viewMode = mode
        case let .previewVisibilityChange(isVisible):
            settings.showsPreview = isVisible
        case let .sidebarWidthChange(width):
            settings.sidebarWidth = width
        case let .operationCompleted(operation, result):
            recordUndoPlan(for: operation, result: result)
        case let .openLocationInNewTab(location):
            onRequestNewTab?(stateForNewTab(at: location))
        case let .removeFavorite(url):
            removeFavorite(url)
        case let .addFavorite(url):
            addFavorite(url)
        case .homePageRefresh:
            reloadVolumes()
        }
    }

    func closeCurrentTab() {
        window?.performClose(self)
    }

    var hasActiveFileOperations: Bool {
        session.hasPendingFileOperations
            || historyTask != nil
            || operationSnapshots.values.contains {
                $0.state == .queued || $0.state == .running
            }
    }

    func cancelActiveFileOperationsAndWait() async {
        historyTask?.cancel()
        await operationQueue.cancelAll()
        await operationQueue.waitUntilIdle()
    }

    func setViewMode(_ mode: BrowserViewMode) { session.setViewMode(mode) }
    var canChangeViewMode: Bool { session.canChangeViewMode }
    func togglePreview() { session.togglePreview() }
    func setShowsHiddenFiles(_ isVisible: Bool) {
        settings.showsHiddenFiles = isVisible
        session.setShowsHiddenFiles(isVisible)
    }
    func setPreviewVisible(_ isVisible: Bool) {
        settings.showsPreview = isVisible
        session.setPreviewVisible(isVisible)
    }
    var isPreviewVisible: Bool { session.showsPreview }
    var canUndo: Bool { historyTask == nil && operationHistory.canUndo }
    var canRedo: Bool { historyTask == nil && operationHistory.canRedo }
    var undoActionName: String? { operationHistory.undoActionName }
    var redoActionName: String? { operationHistory.redoActionName }
    var canAddCurrentFolderToFavorites: Bool {
        guard let url = session.currentLocation?.directoryURL else { return false }
        return canAddFavorite(url)
    }
    func performFileCommand(_ command: BrowserFileCommand) { session.performFileCommand(command) }
    func canPerformFileCommand(_ command: BrowserFileCommand) -> Bool { session.canPerformFileCommand(command) }

    func undoLastOperation() {
        guard historyTask == nil, let plan = operationHistory.take(.undo) else { return }
        performHistory(plan, direction: .undo)
    }

    func redoLastOperation() {
        guard historyTask == nil, let plan = operationHistory.take(.redo) else { return }
        performHistory(plan, direction: .redo)
    }

    func addCurrentFolderToFavorites() {
        guard let url = session.currentLocation?.directoryURL else { return }
        addFavorite(url)
    }

    func reloadNavigationLocations() {
        refreshSidebarLocations()
    }

    func windowDidBecomeKey(_ notification: Notification) { updateWindowTitle(session.displayTitle) }
    func windowDidEndLiveResize(_ notification: Notification) { persistWindowState() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowsCloseWithActiveOperations else { return true }
        guard hasActiveFileOperations else { return true }
        guard !isPresentingCloseConfirmation else { return false }

        isPresentingCloseConfirmation = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File operations are still running."
        alert.informativeText = "Keep this tab open, or cancel its file operations and wait for them to stop before closing."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Cancel Operations and Close")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self else { return }
            self.isPresentingCloseConfirmation = false
            guard response == .alertSecondButtonReturn, let sender else { return }
            self.closeCancellationTask = Task { [weak self, weak sender] in
                guard let self else { return }
                await self.cancelActiveFileOperationsAndWait()
                guard let sender else { return }
                self.allowsCloseWithActiveOperations = true
                self.closeCancellationTask = nil
                sender.performClose(self)
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        persistWindowState()
        session.closeQuickLook()
        session.cancelLoading()
        operationEventTask?.cancel()
        volumeLoadTask?.cancel()
        historyTask?.cancel()
        closeCancellationTask?.cancel()
        onClose?()
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
        onNavigationLocationsChange?()
        session.showStatus("Added \(url.lastPathComponent) to Favorites.")
    }

    private func canAddFavorite(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return !navigationLocations.contains(url)
    }

    private func removeFavorite(_ url: URL) {
        settings.removeFavorite(url)
        onNavigationLocationsChange?()
        session.showStatus("Removed \(url.lastPathComponent) from Favorites.")
    }

    private func refreshSidebarLocations() {
        navigationLocations = buildNavigationLocations()
        session.updateSidebarLocations(navigationLocations.sidebar)
        session.updateHomePage(navigationLocations.homePage)
        session.setOccupiedDirectoryURLs(navigationLocations.occupiedDirectoryURLs)
    }

    private func startSessionIfNeeded() {
        guard !didStartSession else { return }
        didStartSession = true
        session.start(at: initialState.location)
    }

    private func observeOperationEvents() {
        let events = operationQueue.events
        operationEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.session.handleOperationEvent(event)
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
            contentController.setOperationActivity(nil)
            return
        }
        contentController.setOperationActivity(activity(running: running, queuedCount: queued.count))
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
        session.showStatus("\(direction.statusVerb) \(plan.actionName)…")
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
                self.session.refreshContents()
                self.session.showStatus("\(direction.completedVerb) \(plan.actionName).")
            } catch {
                self.operationHistory.restore(plan, direction: direction)
                self.session.showStatus("Unable to \(direction.commandVerb) \(plan.actionName): \(error.localizedDescription)")
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

    private func updateWindowTitle(_ title: String) {
        window?.title = "Explorer — \(title)"
        window?.tab.title = title
        window?.tab.toolTip = title
    }
    private func persistWindowState() { if let window { settings.windowFrame = window.frame } }
}

extension ExplorerWindowController {
    @objc nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { session.canAcceptQuickLookControl }
    }

    @objc nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { session.beginQuickLookControl(panel) }
    }

    @objc nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { session.endQuickLookControl(panel) }
    }
}
