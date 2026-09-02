import AppKit
import ExplorerOperations
import ExplorerUI

@MainActor
final class ExplorerAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowControllers: [ExplorerWindowController] = []
    private let settings = ExplorerSettingsStore()
    private var preferencesWindowController: ExplorerPreferencesWindowController?
    private var didFinishLaunching = false
    private var pendingLaunchURLs: [URL] = []
    private let recoveryJournal = FileOperationRecoveryJournal()
    private var isReplyingToTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [weak self] in
            guard let self else { return }
            let recoveryReport = await recoveryJournal.recoverPendingTransactions()
            didFinishLaunching = true
            let urls = pendingLaunchURLs
            pendingLaunchURLs.removeAll()
            if !urls.isEmpty {
                presentIncomingURLs(urls)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.windowControllers.isEmpty { self.openWindow() }
                self.presentRecoveryReportIfNeeded(recoveryReport)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if didFinishLaunching {
            presentIncomingURLs(urls)
        } else {
            pendingLaunchURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let activeControllers = windowControllers.filter(\.hasActiveFileOperations)
        guard !activeControllers.isEmpty else { return .terminateNow }
        guard !isReplyingToTermination else { return .terminateLater }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File operations are still running."
        alert.informativeText = "Keep Explorer open, or cancel all file operations and wait for them to stop before quitting."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Cancel Operations and Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

        isReplyingToTermination = true
        let tasks = activeControllers.map { controller in
            Task { await controller.cancelActiveFileOperationsAndWait() }
        }
        Task { [weak self] in
            for task in tasks { await task.value }
            self?.isReplyingToTermination = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }

    @objc func navigateBack(_ sender: Any?) {
        currentWindowController?.perform(.back)
    }

    @objc func navigateForward(_ sender: Any?) {
        currentWindowController?.perform(.forward)
    }

    @objc func navigateUp(_ sender: Any?) {
        currentWindowController?.perform(.up)
    }

    @objc func refresh(_ sender: Any?) {
        currentWindowController?.perform(.refresh)
    }

    @objc func newTab(_ sender: Any?) {
        guard let currentWindowController else {
            openWindow()
            return
        }
        openTab(state: currentWindowController.stateForNewTab, relativeTo: currentWindowController)
    }

    @objc func closeTab(_ sender: Any?) {
        currentWindowController?.closeCurrentTab()
    }

    @objc func showDetails(_ sender: Any?) {
        currentWindowController?.setViewMode(.details)
    }

    @objc func showIcons(_ sender: Any?) {
        currentWindowController?.setViewMode(.icons)
    }

    @objc func togglePreview(_ sender: Any?) {
        currentWindowController?.togglePreview()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        applyShowsHiddenFiles(!settings.showsHiddenFiles)
    }

    @objc func showPreferences(_ sender: Any?) {
        let controller: ExplorerPreferencesWindowController
        if let preferencesWindowController {
            controller = preferencesWindowController
        } else {
            controller = ExplorerPreferencesWindowController(settings: settings)
            controller.onShowsHiddenFilesChange = { [weak self] value in self?.applyShowsHiddenFiles(value) }
            controller.onShowsPreviewChange = { [weak self] value in self?.applyShowsPreview(value) }
            preferencesWindowController = controller
        }
        controller.present()
    }

    @objc func undo(_ sender: Any?) { currentWindowController?.undoLastOperation() }
    @objc func redo(_ sender: Any?) { currentWindowController?.redoLastOperation() }
    @objc func addCurrentFolderToFavorites(_ sender: Any?) { currentWindowController?.addCurrentFolderToFavorites() }

    @objc func newFolder(_ sender: Any?) { currentWindowController?.performFileCommand(.newFolder) }
    @objc func rename(_ sender: Any?) { currentWindowController?.performFileCommand(.rename) }
    @objc func copy(_ sender: Any?) { currentWindowController?.performFileCommand(.copy) }
    @objc func cut(_ sender: Any?) { currentWindowController?.performFileCommand(.cut) }
    @objc func paste(_ sender: Any?) { currentWindowController?.performFileCommand(.paste) }
    @objc func duplicate(_ sender: Any?) { currentWindowController?.performFileCommand(.duplicate) }
    @objc func moveToTrash(_ sender: Any?) { currentWindowController?.performFileCommand(.moveToTrash) }
    @objc func deletePermanently(_ sender: Any?) { currentWindowController?.performFileCommand(.deletePermanently) }
    @objc func quickLook(_ sender: Any?) { currentWindowController?.performFileCommand(.quickLook) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = currentWindowController?.undoActionName.map { "Undo \($0)" } ?? "Undo"
            return currentWindowController?.canUndo ?? false
        case #selector(redo(_:)):
            menuItem.title = currentWindowController?.redoActionName.map { "Redo \($0)" } ?? "Redo"
            return currentWindowController?.canRedo ?? false
        case #selector(showDetails(_:)), #selector(showIcons(_:)):
            return currentWindowController?.canChangeViewMode ?? false
        case #selector(newFolder(_:)): return currentWindowController?.canPerformFileCommand(.newFolder) ?? false
        case #selector(rename(_:)): return currentWindowController?.canPerformFileCommand(.rename) ?? false
        case #selector(copy(_:)): return currentWindowController?.canPerformFileCommand(.copy) ?? false
        case #selector(cut(_:)): return currentWindowController?.canPerformFileCommand(.cut) ?? false
        case #selector(paste(_:)): return currentWindowController?.canPerformFileCommand(.paste) ?? false
        case #selector(duplicate(_:)): return currentWindowController?.canPerformFileCommand(.duplicate) ?? false
        case #selector(moveToTrash(_:)): return currentWindowController?.canPerformFileCommand(.moveToTrash) ?? false
        case #selector(deletePermanently(_:)): return currentWindowController?.canPerformFileCommand(.deletePermanently) ?? false
        case #selector(quickLook(_:)): return currentWindowController?.canPerformFileCommand(.quickLook) ?? false
        case #selector(togglePreview(_:)):
            menuItem.state = currentWindowController?.isPreviewVisible == true ? .on : .off
            return currentWindowController != nil
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = settings.showsHiddenFiles ? .on : .off
            return true
        case #selector(addCurrentFolderToFavorites(_:)):
            return currentWindowController?.canAddCurrentFolderToFavorites ?? false
        default: return true
        }
    }

    private var currentWindowController: ExplorerWindowController? {
        NSApp.keyWindow?.windowController as? ExplorerWindowController
            ?? windowControllers.last(where: { $0.window?.isVisible == true })
    }

    private func presentIncomingURLs(_ urls: [URL]) {
        let locations = ExplorerOpenURLResolver.locations(for: urls)
        guard !locations.isEmpty else { return }
        var current = currentWindowController ?? windowControllers.last
        for location in locations {
            if let parent = current {
                current = openTab(
                    state: parent.stateForNewTab(at: location),
                    relativeTo: parent
                )
            } else {
                current = openWindow(
                    initialState: ExplorerWindowState(
                        location: location,
                        viewMode: settings.viewMode,
                        sortDescriptor: .nameAscending
                    )
                )
            }
        }
        current?.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func openWindow(
        initialState: ExplorerWindowState? = nil,
        tabbedWith parent: ExplorerWindowController? = nil
    ) -> ExplorerWindowController {
        let controller = ExplorerWindowController(
            initialState: initialState,
            recoveryJournal: recoveryJournal
        )
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
        controller.onRequestNewTab = { [weak self, weak controller] state in
            guard let self, let controller else { return }
            self.openTab(state: state, relativeTo: controller)
        }
        controller.onNavigationLocationsChange = { [weak self] in
            self?.windowControllers.forEach { $0.reloadNavigationLocations() }
        }
        windowControllers.append(controller)
        controller.showWindow(self)
        if let parentWindow = parent?.window, let newWindow = controller.window {
            parentWindow.addTabbedWindow(newWindow, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    @discardableResult
    private func openTab(
        state: ExplorerWindowState,
        relativeTo parent: ExplorerWindowController
    ) -> ExplorerWindowController {
        openWindow(initialState: state, tabbedWith: parent)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem())

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t").target = self
        let newFolder = fileMenu.addItem(withTitle: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        newFolder.target = self
        let rename = fileMenu.addItem(withTitle: "Rename", action: #selector(rename(_:)), keyEquivalent: "\u{F705}")
        rename.target = self
        let duplicate = fileMenu.addItem(withTitle: "Duplicate", action: #selector(duplicate(_:)), keyEquivalent: "d")
        duplicate.target = self
        fileMenu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash(_:)), keyEquivalent: "").target = self
        let deleteImmediately = fileMenu.addItem(
            withTitle: "Delete Immediately…",
            action: #selector(deletePermanently(_:)),
            keyEquivalent: ""
        )
        deleteImmediately.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w").target = self
        let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        addMenuItem("Undo", action: #selector(undo(_:)), key: "z", modifiers: .command, to: editMenu)
        addMenuItem("Redo", action: #selector(redo(_:)), key: "z", modifiers: [.command, .shift], to: editMenu)
        editMenu.addItem(.separator())
        addMenuItem("Copy", action: #selector(copy(_:)), key: "c", modifiers: .command, to: editMenu)
        addMenuItem("Cut", action: #selector(cut(_:)), key: "x", modifiers: .command, to: editMenu)
        addMenuItem("Paste", action: #selector(paste(_:)), key: "v", modifiers: .command, to: editMenu)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let goMenu = NSMenu(title: "Go")
        addMenuItem("Back", action: #selector(navigateBack(_:)), key: "[", modifiers: .command, to: goMenu)
        addMenuItem("Forward", action: #selector(navigateForward(_:)), key: "]", modifiers: .command, to: goMenu)
        addMenuItem("Enclosing Folder", action: #selector(navigateUp(_:)), key: "\u{F700}", modifiers: [.command, .option], to: goMenu)
        addMenuItem("Refresh", action: #selector(refresh(_:)), key: "r", modifiers: .command, to: goMenu)
        goMenu.addItem(.separator())
        addMenuItem("Add Current Folder to Favorites", action: #selector(addCurrentFolderToFavorites(_:)), key: "d", modifiers: [.command, .control], to: goMenu)
        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let viewMenu = NSMenu(title: "View")
        addMenuItem("as Details", action: #selector(showDetails(_:)), key: "1", modifiers: .command, to: viewMenu)
        addMenuItem("as Icons", action: #selector(showIcons(_:)), key: "2", modifiers: .command, to: viewMenu)
        viewMenu.addItem(.separator())
        addMenuItem("Hidden Files", action: #selector(toggleHiddenFiles(_:)), key: ".", modifiers: [.command, .shift], to: viewMenu)
        addMenuItem("Preview Pane", action: #selector(togglePreview(_:)), key: "p", modifiers: [.command, .shift], to: viewMenu)
        addMenuItem("Quick Look", action: #selector(quickLook(_:)), key: " ", modifiers: [], to: viewMenu)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        NSApp.mainMenu = mainMenu
    }

    private func applicationMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Explorer")
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Explorer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Explorer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let item = NSMenuItem(title: "Explorer", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func applyShowsHiddenFiles(_ isVisible: Bool) {
        settings.showsHiddenFiles = isVisible
        windowControllers.forEach { $0.setShowsHiddenFiles(isVisible) }
    }

    private func applyShowsPreview(_ isVisible: Bool) {
        settings.showsPreview = isVisible
        windowControllers.forEach { $0.setPreviewVisible(isVisible) }
    }

    private func presentRecoveryReportIfNeeded(_ report: FileOperationRecoveryReport) {
        guard report.didFindPendingWork else { return }
        let alert = NSAlert()
        if report.failures.isEmpty {
            alert.alertStyle = .informational
            alert.messageText = "Interrupted file operations were recovered."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Some interrupted file operations need attention."
        }

        var details: [String] = []
        if !report.restoredDestinations.isEmpty {
            details.append("Restored \(report.restoredDestinations.count) original item(s).")
        }
        if !report.finalizedDestinations.isEmpty {
            details.append("Finished cleaning up \(report.finalizedDestinations.count) completed replacement(s).")
        }
        if !report.discardedTransfers.isEmpty {
            details.append("Removed \(report.discardedTransfers.count) incomplete temporary transfer(s).")
        }
        if !report.completedTransfers.isEmpty {
            details.append("Finished \(report.completedTransfers.count) interrupted transfer(s).")
        }
        if !report.failures.isEmpty {
            details.append("Could not recover \(report.failures.count) item(s). Recovery records were preserved for another attempt.")
        }
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if let window = currentWindowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func addMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
    }
}
