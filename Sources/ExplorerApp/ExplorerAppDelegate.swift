import AppKit
import ExplorerUI

@MainActor
final class ExplorerAppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [ExplorerWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        openWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        currentWindowController?.newTab()
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
    @objc func quickLook(_ sender: Any?) { currentWindowController?.performFileCommand(.quickLook) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = currentWindowController?.undoActionName.map { "Undo \($0)" } ?? "Undo"
            return currentWindowController?.canUndo ?? false
        case #selector(redo(_:)):
            menuItem.title = currentWindowController?.redoActionName.map { "Redo \($0)" } ?? "Redo"
            return currentWindowController?.canRedo ?? false
        case #selector(newFolder(_:)): return currentWindowController?.canPerformFileCommand(.newFolder) ?? false
        case #selector(rename(_:)): return currentWindowController?.canPerformFileCommand(.rename) ?? false
        case #selector(copy(_:)): return currentWindowController?.canPerformFileCommand(.copy) ?? false
        case #selector(cut(_:)): return currentWindowController?.canPerformFileCommand(.cut) ?? false
        case #selector(paste(_:)): return currentWindowController?.canPerformFileCommand(.paste) ?? false
        case #selector(duplicate(_:)): return currentWindowController?.canPerformFileCommand(.duplicate) ?? false
        case #selector(moveToTrash(_:)): return currentWindowController?.canPerformFileCommand(.moveToTrash) ?? false
        case #selector(quickLook(_:)): return currentWindowController?.canPerformFileCommand(.quickLook) ?? false
        case #selector(togglePreview(_:)):
            menuItem.state = currentWindowController?.isPreviewVisible == true ? .on : .off
            return currentWindowController != nil
        case #selector(addCurrentFolderToFavorites(_:)):
            return currentWindowController?.canAddCurrentFolderToFavorites ?? false
        default: return true
        }
    }

    private var currentWindowController: ExplorerWindowController? {
        NSApp.keyWindow?.windowController as? ExplorerWindowController
            ?? windowControllers.last(where: { $0.window?.isVisible == true })
    }

    private func openWindow() {
        let controller = ExplorerWindowController()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
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
        let trash = fileMenu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash(_:)), keyEquivalent: "\u{8}")
        trash.keyEquivalentModifierMask = .command
        trash.target = self
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
        addMenuItem("Show Preview Pane", action: #selector(togglePreview(_:)), key: "p", modifiers: [.command, .shift], to: viewMenu)
        addMenuItem("Quick Look", action: #selector(quickLook(_:)), key: " ", modifiers: [], to: viewMenu)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        NSApp.mainMenu = mainMenu
    }

    private func applicationMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Explorer")
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
