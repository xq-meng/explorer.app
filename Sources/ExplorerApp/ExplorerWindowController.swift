import AppKit
import ExplorerBrowsing
import ExplorerOperations
import ExplorerUI

@MainActor
final class ExplorerWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
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

    init() {
        let defaultFrame = NSRect(x: 0, y: 0, width: 1080, height: 680)
        let storedFrame = settings.windowFrame
        let frame = (storedFrame?.width ?? 0) >= 720 && (storedFrame?.height ?? 0) >= 440 ? storedFrame! : defaultFrame
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Explorer"
        window.minSize = NSSize(width: 720, height: 440)
        window.contentViewController = tabViewController
        if storedFrame == nil { window.center() }
        super.init(window: window)
        window.delegate = self
        tabViewController.onSelectionChange = { [weak self] in
            self?.sessions.forEach { $0.closeQuickLook() }
            self?.updateWindowTitle()
            self?.updateViewModeToolbarSelection()
            self?.persistSessionState()
        }
        configureToolbar(for: window)
        observeOperationEvents()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        restoreSessionIfNeeded()
        startVolumeLoading()
    }

    func perform(_ command: BrowserNavigationCommand) { currentSession?.perform(command) }

    func newTab(at url: URL? = nil) {
        let startingURL = url ?? currentSession?.currentDirectoryURL ?? homeURL
        let session = ExplorerTabController(
            homeURL: homeURL,
            sidebarLocations: allSidebarLocations,
            initialViewMode: restoredViewMode,
            initialShowsPreview: restoredPreviewVisibility,
            sidebarWidth: settings.sidebarWidth,
            operationQueue: operationQueue,
            clipboard: clipboard
        )
        let item = NSTabViewItem(viewController: session)
        item.label = "Loading…"
        session.onTitleChange = { [weak self, weak item, weak session] title in
            item?.label = title
            guard self?.currentSession === session else { return }
            self?.window?.title = "Explorer — \(title)"
            self?.persistSessionState()
        }
        session.onViewModeChange = { [weak self] mode in
            self?.settings.viewMode = mode
            self?.updateViewModeToolbarSelection()
        }
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
        updateViewModeToolbarSelection()
        persistSessionState()
    }

    func closeCurrentTab() {
        guard let item = selectedTabItem, let session = item.viewController as? ExplorerTabController else { return }
        guard tabViewController.tabViewItems.count > 1 else { window?.performClose(self); return }
        session.cancelLoading()
        sessions.removeAll { $0 === session }
        tabViewController.removeTabViewItem(item)
        updateWindowTitle()
        updateViewModeToolbarSelection()
        persistSessionState()
    }

    func setViewMode(_ mode: BrowserViewMode) { currentSession?.setViewMode(mode) }
    func togglePreview() { currentSession?.togglePreview() }
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

    func windowDidBecomeKey(_ notification: Notification) { updateWindowTitle(); updateViewModeToolbarSelection() }
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

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newTab, .back, .forward, .up, .refresh, .viewMode, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newTab, .back, .forward, .up, .flexibleSpace, .viewMode, .refresh]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .newTab: configure(item, "New Tab", "Open New Tab", "plus", #selector(openNewTab(_:)))
        case .back: configure(item, "Back", "Go Back", "chevron.left", #selector(goBack(_:)))
        case .forward: configure(item, "Forward", "Go Forward", "chevron.right", #selector(goForward(_:)))
        case .up: configure(item, "Up", "Go to Enclosing Folder", "arrow.up", #selector(goUp(_:)))
        case .refresh: configure(item, "Refresh", "Refresh Folder", "arrow.clockwise", #selector(refresh(_:)))
        case .viewMode:
            let control = NSSegmentedControl(labels: ["Details", "Icons"], trackingMode: .selectOne, target: self, action: #selector(changeViewMode(_:)))
            control.setAccessibilityLabel("View mode")
            control.selectedSegment = currentSession?.viewMode == .icons ? 1 : 0
            item.label = "View Mode"; item.paletteLabel = "View Mode"; item.toolTip = "Choose details or icon view"; item.view = control
        default: return nil
        }
        return item
    }

    private var selectedTabItem: NSTabViewItem? {
        let index = tabViewController.selectedTabViewItemIndex
        guard tabViewController.tabViewItems.indices.contains(index) else { return nil }
        return tabViewController.tabViewItems[index]
    }
    private var currentSession: ExplorerTabController? { selectedTabItem?.viewController as? ExplorerTabController }
    private var restoredViewMode: BrowserViewMode { settings.viewMode }
    private var restoredPreviewVisibility: Bool { settings.showsPreview }

    private var standardSidebarLocations: [BrowserSidebarLocation] {
        var locations = [BrowserSidebarLocation(title: "Home", url: homeURL, kind: .favorite)]
        for name in ["Desktop", "Documents", "Downloads"] {
            let url = homeURL.appendingPathComponent(name, isDirectory: true)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                locations.append(BrowserSidebarLocation(title: name, url: url, kind: .favorite))
            }
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
        if restored.locations.isEmpty {
            newTab(at: homeURL)
        } else {
            restored.locations.forEach { newTab(at: $0) }
            tabViewController.selectedTabViewItemIndex = min(max(0, restored.selectedIndex), sessions.count - 1)
        }
        isRestoringSession = false
        persistSessionState()
    }

    private func persistSessionState() {
        guard !isRestoringSession else { return }
        settings.saveTabSession(
            locations: sessions.compactMap(\.currentDirectoryURL),
            selectedIndex: tabViewController.selectedTabViewItemIndex
        )
    }

    private func observeOperationEvents() {
        let events = operationQueue.events
        operationEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.sessions.forEach { $0.handleOperationEvent(event) }
            }
        }
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

    private func configureToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "ExplorerToolbar")
        toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true; toolbar.delegate = self
        window.toolbar = toolbar; window.toolbarStyle = .unified
    }

    private func configure(_ item: NSToolbarItem, _ label: String, _ toolTip: String, _ imageName: String, _ action: Selector) {
        item.label = label; item.paletteLabel = label; item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: label); item.target = self; item.action = action
    }

    private func updateWindowTitle() { if let session = currentSession { window?.title = "Explorer — \(session.displayTitle)" } }
    private func updateViewModeToolbarSelection() {
        guard let toolbar = window?.toolbar, let item = toolbar.items.first(where: { $0.itemIdentifier == .viewMode }), let control = item.view as? NSSegmentedControl else { return }
        control.selectedSegment = currentSession?.viewMode == .icons ? 1 : 0
    }
    private func persistWindowState() { if let window { settings.windowFrame = window.frame } }

    @objc private func openNewTab(_ sender: Any?) { newTab() }
    @objc private func goBack(_ sender: Any?) { perform(.back) }
    @objc private func goForward(_ sender: Any?) { perform(.forward) }
    @objc private func goUp(_ sender: Any?) { perform(.up) }
    @objc private func refresh(_ sender: Any?) { perform(.refresh) }
    @objc private func changeViewMode(_ sender: NSSegmentedControl) { setViewMode(sender.selectedSegment == 1 ? .icons : .details) }
}

@MainActor
private final class ExplorerTabsViewController: NSTabViewController {
    var onSelectionChange: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelectionChange?()
    }
}

private extension NSToolbarItem.Identifier {
    static let newTab = Self("Explorer.newTab")
    static let back = Self("Explorer.back")
    static let forward = Self("Explorer.forward")
    static let up = Self("Explorer.up")
    static let refresh = Self("Explorer.refresh")
    static let viewMode = Self("Explorer.viewMode")
}
