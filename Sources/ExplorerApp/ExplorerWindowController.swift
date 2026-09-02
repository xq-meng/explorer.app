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
    private let clipboard: FileClipboardService
    private let mountedVolumeService: MountedVolumeService
    private var sessions: [ExplorerTabController]
    private var activeSession: ExplorerTabController
    private let contentController: ExplorerWindowContentViewController
    private var mountedVolumes: [MountedVolumeMetadata] = []
    private var navigationLocations: ExplorerNavigationLocations
    private var operationEventTask: Task<Void, Never>?
    private var volumeLoadTask: Task<Void, Never>?
    private var didStartVolumeLoading = false
    private var operationHistory = FileOperationHistory()
    private var historyTask: Task<Void, Never>?
    private var didStartSession = false
    private var didRestoreDualPane = false
    private let initialState: ExplorerWindowState
    private let restoresSavedDualPaneSession: Bool
    private var operationSnapshots: [UUID: FileOperationQueueSnapshot] = [:]
    private var operationProgress: [UUID: FileOperationProgress] = [:]
    private var operationOrder: [UUID] = []
    private var isPresentingCloseConfirmation = false
    private var allowsCloseWithActiveOperations = false
    private var closeCancellationTask: Task<Void, Never>?
    private var paneRestorationTask: Task<Void, Never>?
    private var paneActivationEventMonitor: Any?

    init(
        initialState: ExplorerWindowState? = nil,
        recoveryJournal: FileOperationRecoveryJournal = FileOperationRecoveryJournal(),
        operationQueue injectedOperationQueue: FileOperationQueue? = nil,
        settings injectedSettings: ExplorerSettingsStore? = nil,
        restoresSavedDualPaneSession: Bool = false
    ) {
        let settings = injectedSettings ?? ExplorerSettingsStore()
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
            initialViewMode: resolvedState.viewMode,
            initialSortDescriptor: resolvedState.sortDescriptor,
            initialShowsPreview: settings.showsPreview,
            initialShowsHiddenFiles: settings.showsHiddenFiles,
            homePageModel: navigationLocations.homePage,
            operationQueue: operationQueue,
            clipboard: clipboard
        )
        let contentController = ExplorerWindowContentViewController(
            browserController: session,
            sidebarLocations: navigationLocations.sidebar,
            sidebarWidth: settings.sidebarWidth
        )

        self.settings = settings
        self.homeURL = homeURL
        self.operationQueue = operationQueue
        self.clipboard = clipboard
        self.mountedVolumeService = mountedVolumeService
        sessions = [session]
        activeSession = session
        self.contentController = contentController
        self.navigationLocations = navigationLocations
        self.initialState = resolvedState
        self.restoresSavedDualPaneSession = restoresSavedDualPaneSession

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
        contentController.onSidebarWidthChange = { [weak self] width in
            self?.settings.sidebarWidth = width
        }
        contentController.onSidebarAction = { [weak self] action in
            _ = self?.activeSession.performSidebarAction(action)
        }
        configureSession(session)
        observeOperationEvents()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        installPaneActivationEventMonitorIfNeeded()
        startSessionIfNeeded()
        restoreDualPaneIfNeeded()
        startVolumeLoading()
    }

    func perform(_ command: BrowserNavigationCommand) { activeSession.perform(command) }

    var stateForNewTab: ExplorerWindowState {
        ExplorerWindowState(
            location: activeSession.currentLocation ?? .computer,
            viewMode: activeSession.viewMode,
            sortDescriptor: activeSession.sortDescriptor
        )
    }

    func stateForNewTab(at location: BrowserLocation) -> ExplorerWindowState {
        ExplorerWindowState(
            location: location,
            viewMode: activeSession.viewMode,
            sortDescriptor: activeSession.sortDescriptor
        )
    }

    @IBAction override func newWindowForTab(_ sender: Any?) {
        onRequestNewTab?(stateForNewTab)
    }

    private func handle(_ event: ExplorerTabEvent, from session: ExplorerTabController) {
        switch event {
        case let .titleChange(title):
            if session === activeSession { updateWindowTitle(title) }
        case let .viewModeChange(mode):
            settings.viewMode = mode
        case let .previewVisibilityChange(isVisible):
            settings.showsPreview = isVisible
        case let .operationCompleted(operation, result):
            recordUndoPlan(for: operation, result: result)
        case let .openLocationInNewTab(location):
            onRequestNewTab?(stateForNewTab(at: location))
        case .toggleDualPane:
            setDualPaneEnabled(!isDualPaneEnabled)
        case let .removeFavorite(url):
            removeFavorite(url)
        case let .addFavorite(url):
            addFavorite(url)
        case .homePageRefresh:
            reloadVolumes()
        case .restorationStateChange:
            persistDualPaneRestorationState()
            if session === activeSession { synchronizeSharedSidebar() }
        case let .viewStateChange(state):
            if session === activeSession { contentController.setSidebarViewState(state) }
        }
    }

    func closeCurrentTab() {
        window?.performClose(self)
    }

    var hasActiveFileOperations: Bool {
        sessions.contains(where: \.hasPendingFileOperations)
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

    func setViewMode(_ mode: BrowserViewMode) { activeSession.setViewMode(mode) }
    var canChangeViewMode: Bool { activeSession.canChangeViewMode }
    func togglePreview() { setPreviewVisible(!settings.showsPreview) }
    func setShowsHiddenFiles(_ isVisible: Bool) {
        settings.showsHiddenFiles = isVisible
        sessions.forEach { $0.setShowsHiddenFiles(isVisible) }
    }
    func setPreviewVisible(_ isVisible: Bool) {
        settings.showsPreview = isVisible
        sessions.forEach { $0.setPreviewVisible(isVisible) }
        updatePanePresentations()
    }
    var isPreviewVisible: Bool { settings.showsPreview }
    var isDualPaneEnabled: Bool { sessions.count == 2 }
    var activePaneIndex: Int? { sessions.firstIndex { $0 === activeSession } }
    var canFocusOtherPane: Bool { isDualPaneEnabled }
    var canTransferSelectionToOtherPane: Bool {
        guard let other = otherSession,
              let destination = other.currentDirectoryURL,
              !activeSession.selection.isEmpty else { return false }
        return activeSession.currentDirectoryURL != destination
    }
    var canUndo: Bool { historyTask == nil && operationHistory.canUndo }
    var canRedo: Bool { historyTask == nil && operationHistory.canRedo }
    var undoActionName: String? { operationHistory.undoActionName }
    var redoActionName: String? { operationHistory.redoActionName }
    var canAddCurrentFolderToFavorites: Bool {
        guard let url = activeSession.currentLocation?.directoryURL else { return false }
        return canAddFavorite(url)
    }
    func performFileCommand(_ command: BrowserFileCommand) { activeSession.performFileCommand(command) }
    func canPerformFileCommand(_ command: BrowserFileCommand) -> Bool { activeSession.canPerformFileCommand(command) }

    func toggleDualPane() {
        setDualPaneEnabled(!isDualPaneEnabled)
    }

    func setDualPaneEnabled(_ isEnabled: Bool) {
        guard isEnabled != isDualPaneEnabled else { return }
        if isEnabled {
            let primary = activeSession
            let secondary = makeSession(
                viewMode: primary.viewMode,
                sortDescriptor: primary.sortDescriptor
            )
            sessions.append(secondary)
            configureSession(secondary)
            contentController.showSplitPane(
                primary: primary,
                secondary: secondary
            )
            if didStartSession {
                secondary.start(at: primary.currentLocation ?? initialState.location)
            }
            settings.dualPaneEnabled = true
        } else {
            guard !sessions.contains(where: \.hasPendingFileOperations) else {
                activeSession.showStatus("Wait for pane file operations to finish before closing split view.")
                return
            }
            persistDualPaneRestorationState()
            let survivor = activeSession
            let removedSessions = sessions.filter { $0 !== survivor }
            removedSessions.forEach {
                $0.closeQuickLook()
                $0.cancelLoading()
            }
            sessions = [survivor]
            contentController.showSinglePane(survivor)
            settings.dualPaneEnabled = false
        }
        updatePanePresentations()
        updateWindowTitle(activeSession.displayTitle)
        persistDualPaneRestorationState()
    }

    func focusOtherPane() {
        guard let other = otherSession else { return }
        activate(other, focusContent: true)
    }

    func copySelectionToOtherPane() {
        transferSelectionToOtherPane(isMove: false)
    }

    func moveSelectionToOtherPane() {
        transferSelectionToOtherPane(isMove: true)
    }

    func undoLastOperation() {
        guard historyTask == nil, let plan = operationHistory.take(.undo) else { return }
        performHistory(plan, direction: .undo)
    }

    func redoLastOperation() {
        guard historyTask == nil, let plan = operationHistory.take(.redo) else { return }
        performHistory(plan, direction: .redo)
    }

    func addCurrentFolderToFavorites() {
        guard let url = activeSession.currentLocation?.directoryURL else { return }
        addFavorite(url)
    }

    func reloadNavigationLocations() {
        refreshSidebarLocations()
    }

    func windowDidBecomeKey(_ notification: Notification) { updateWindowTitle(activeSession.displayTitle) }
    func windowDidResignKey(_ notification: Notification) { persistWindowState() }
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
        sessions.forEach {
            $0.closeQuickLook()
            $0.cancelLoading()
        }
        operationEventTask?.cancel()
        volumeLoadTask?.cancel()
        historyTask?.cancel()
        closeCancellationTask?.cancel()
        paneRestorationTask?.cancel()
        removePaneActivationEventMonitor()
        onClose?()
    }

    private var otherSession: ExplorerTabController? {
        sessions.first { $0 !== activeSession }
    }

    private func makeSession(
        viewMode: BrowserViewMode,
        sortDescriptor: BrowserSortDescriptor
    ) -> ExplorerTabController {
        ExplorerTabController(
            homeURL: homeURL,
            initialViewMode: viewMode,
            initialSortDescriptor: sortDescriptor,
            initialShowsPreview: settings.showsPreview,
            initialShowsHiddenFiles: settings.showsHiddenFiles,
            homePageModel: navigationLocations.homePage,
            operationQueue: operationQueue,
            clipboard: clipboard
        )
    }

    private func configureSession(_ session: ExplorerTabController) {
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.handle(event, from: session)
        }
        session.onActivate = { [weak self, weak session] in
            guard let self, let session else { return }
            self.activate(session)
        }
        session.setOccupiedDirectoryURLs(navigationLocations.occupiedDirectoryURLs)
        updatePanePresentations()
    }

    private func restoreDualPaneIfNeeded() {
        guard !didRestoreDualPane else { return }
        didRestoreDualPane = true
        guard restoresSavedDualPaneSession else {
            updatePanePresentations()
            return
        }
        guard settings.dualPaneEnabled else {
            updatePanePresentations()
            return
        }

        guard let savedState = settings.dualPaneRestorationState else {
            setDualPaneEnabled(true)
            return
        }
        let fallbackLocation = initialState.location
        paneRestorationTask = Task { [weak self] in
            let restoredPanes = await Self.validatedRestorationStates(
                savedState.panes,
                fallback: fallbackLocation
            )
            guard !Task.isCancelled, let self,
                  self.settings.dualPaneEnabled, self.sessions.count == 1 else { return }
            self.installRestoredDualPane(
                restoredPanes,
                activePaneIndex: savedState.activePaneIndex
            )
            self.paneRestorationTask = nil
        }
    }

    private func installRestoredDualPane(
        _ restoredPanes: [ExplorerPaneRestorationState],
        activePaneIndex: Int
    ) {
        guard restoredPanes.count == 2 else { return }
        let primary = sessions[0]
        let secondary = makeSession(
            viewMode: restoredPanes[1].viewMode,
            sortDescriptor: restoredPanes[1].sortDescriptor
        )
        sessions.append(secondary)
        configureSession(secondary)
        activeSession = sessions[min(max(0, activePaneIndex), sessions.count - 1)]
        contentController.showSplitPane(
            primary: primary,
            secondary: secondary
        )
        primary.restore(from: restoredPanes[0])
        secondary.restore(from: restoredPanes[1])
        updatePanePresentations()
        updateWindowTitle(activeSession.displayTitle)
    }

    private func activate(_ session: ExplorerTabController, focusContent: Bool = false) {
        guard sessions.contains(where: { $0 === session }) else { return }
        if activeSession !== session {
            activeSession.closeQuickLook()
            activeSession = session
            updatePanePresentations()
            updateWindowTitle(session.displayTitle)
        }
        synchronizeSharedSidebar()
        if focusContent { session.focusFileContent() }
        persistDualPaneRestorationState()
    }

    private func installPaneActivationEventMonitorIfNeeded() {
        guard paneActivationEventMonitor == nil else { return }
        paneActivationEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, event.window === self.window,
                  let contentView = self.window?.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            guard let hitView = contentView.hitTest(point),
                  let session = self.sessions.first(where: { session in
                      hitView === session.view || hitView.isDescendant(of: session.view)
                  }) else { return event }
            self.activate(session)
            return event
        }
    }

    private func removePaneActivationEventMonitor() {
        guard let paneActivationEventMonitor else { return }
        NSEvent.removeMonitor(paneActivationEventMonitor)
        self.paneActivationEventMonitor = nil
    }

    private func updatePanePresentations() {
        let isDualPane = isDualPaneEnabled
        for session in sessions {
            session.browser.setSidebarVisible(false)
            session.configurePanePresentation(
                isActive: session === activeSession,
                isDualPane: isDualPane
            )
        }
        synchronizeSharedSidebar()
    }

    private func synchronizeSharedSidebar() {
        contentController.setSidebarViewState(activeSession.browser.viewState)
        contentController.selectSidebarLocation(activeSession.currentLocation)
    }

    private func transferSelectionToOtherPane(isMove: Bool) {
        guard canTransferSelectionToOtherPane,
              let destinationSession = otherSession,
              let destination = destinationSession.currentDirectoryURL else { return }
        let sources = activeSession.selection.sorted { $0.path < $1.path }
        let operation: FileOperation = isMove
            ? .move(sources: sources, to: destination, conflictPolicy: .ask)
            : .copy(sources: sources, to: destination, conflictPolicy: .ask)
        activeSession.submit(operation) { [weak destinationSession] _ in
            destinationSession?.refreshContents()
        }
    }

    private func buildNavigationLocations() -> ExplorerNavigationLocations {
        ExplorerNavigationLocationBuilder.build(
            homeURL: homeURL,
            favoriteURLs: settings.favoriteURLs,
            mountedVolumes: mountedVolumes,
            isDirectory: Self.isDirectory
        )
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func validatedRestorationStates(
        _ states: [ExplorerPaneRestorationState],
        fallback: BrowserLocation
    ) async -> [ExplorerPaneRestorationState] {
        var restoredStates: [ExplorerPaneRestorationState] = []
        restoredStates.reserveCapacity(states.count)
        for state in states {
            guard !Task.isCancelled else { return [] }
            restoredStates.append(validatedRestorationState(state, fallback: fallback))
        }
        return restoredStates
    }

    private nonisolated static func validatedRestorationState(
        _ state: ExplorerPaneRestorationState,
        fallback: BrowserLocation
    ) -> ExplorerPaneRestorationState {
        let restoredLocation = validRestorationLocation(state.location)
        let fallback = validRestorationLocation(fallback) ?? .computer
        let location = restoredLocation ?? fallback
        return ExplorerPaneRestorationState(
            location: location,
            backHistory: state.backHistory.compactMap(validRestorationLocation),
            forwardHistory: state.forwardHistory.compactMap(validRestorationLocation),
            selection: restoredLocation == nil
                ? []
                : state.selection.map { $0.resolvingSymlinksInPath().standardizedFileURL },
            viewMode: state.viewMode,
            sortDescriptor: state.sortDescriptor,
            scrollPosition: restoredLocation == nil ? nil : state.scrollPosition.map {
                BrowserScrollPosition(
                    anchorURL: $0.anchorURL?.resolvingSymlinksInPath(),
                    horizontalOffset: $0.horizontalOffset,
                    verticalOffset: $0.verticalOffset,
                    anchorVerticalOffset: $0.anchorVerticalOffset
                )
            }
        )
    }

    private nonisolated static func validRestorationLocation(
        _ location: BrowserLocation
    ) -> BrowserLocation? {
        switch location {
        case .computer:
            return .computer
        case let .directory(url):
            let standardizedURL = url.standardizedFileURL
            return Self.isDirectory(standardizedURL) ? .directory(standardizedURL) : nil
        }
    }

    private func addFavorite(_ url: URL) {
        let url = url.standardizedFileURL
        guard canAddFavorite(url) else { return }
        settings.addFavorite(url)
        onNavigationLocationsChange?()
        activeSession.showStatus("Added \(url.lastPathComponent) to Favorites.")
    }

    private func canAddFavorite(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return !navigationLocations.contains(url)
    }

    private func removeFavorite(_ url: URL) {
        settings.removeFavorite(url)
        onNavigationLocationsChange?()
        activeSession.showStatus("Removed \(url.lastPathComponent) from Favorites.")
    }

    private func refreshSidebarLocations() {
        navigationLocations = buildNavigationLocations()
        contentController.displaySidebarLocations(navigationLocations.sidebar)
        sessions.forEach {
            $0.updateHomePage(navigationLocations.homePage)
            $0.setOccupiedDirectoryURLs(navigationLocations.occupiedDirectoryURLs)
        }
    }

    private func startSessionIfNeeded() {
        guard !didStartSession else { return }
        didStartSession = true
        sessions.first?.start(at: initialState.location)
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
        let session = activeSession
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
                self.sessions.forEach { $0.refreshContents() }
                session.showStatus("\(direction.completedVerb) \(plan.actionName).")
            } catch {
                self.operationHistory.restore(plan, direction: direction)
                session.showStatus("Unable to \(direction.commandVerb) \(plan.actionName): \(error.localizedDescription)")
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
    func persistDualPaneRestorationState() {
        guard sessions.count == 2 else { return }
        let paneStates = sessions.compactMap { $0.restorationState() }
        guard paneStates.count == 2, let activePaneIndex else { return }
        settings.dualPaneRestorationState = ExplorerDualPaneRestorationState(
            panes: paneStates,
            activePaneIndex: activePaneIndex
        )
    }

    func persistRestorableState() {
        persistWindowState()
    }

    private func persistWindowState() {
        if let window { settings.windowFrame = window.frame }
        persistDualPaneRestorationState()
    }
}

extension ExplorerWindowController {
    @objc nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { activeSession.canAcceptQuickLookControl }
    }

    @objc nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { activeSession.beginQuickLookControl(panel) }
    }

    @objc nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { activeSession.endQuickLookControl(panel) }
    }
}
