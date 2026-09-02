import AppKit

/// Builds the shared location menu used by the sidebar and My Computer tiles.
@MainActor
enum BrowserLocationContextMenuBuilder {
    static func rebuild(
        _ menu: NSMenu,
        for location: BrowserSidebarLocation,
        viewState: BrowserViewState,
        target: AnyObject,
        action: Selector
    ) {
        menu.removeAllItems()
        let locationActions: [(String, String, BrowserAction)] = [
            ("location.open", "Open", .openLocation(location.location)),
            ("location.openInNewTab", "Open in New Tab", .openLocationInNewTab(location.location)),
        ]
        add(locationActions, to: menu, target: target, action: action)

        guard let url = location.directoryURL else { return }
        addSeparator(to: menu)
        add([
            ("location.showInFinder", "Show in Finder", .revealInFinder(url)),
            ("location.copyPath", "Copy Path", .copyPath(url)),
        ], to: menu, target: target, action: action)

        addSeparator(to: menu)
        add([
            ("location.newFolder", "New Folder", .createFolder(in: url)),
        ], to: menu, target: target, action: action)

        var favoriteActions: [(String, String, BrowserAction)] = []
        if viewState.canAddFavorite(at: url) {
            favoriteActions.append(("location.addFavorite", "Add to Favorites", .addFavorite(url)))
        }
        if location.isRemovable {
            favoriteActions.append((
                "location.removeFavorite",
                "Remove from Favorites",
                .removeFavorite(url)
            ))
        }
        if !favoriteActions.isEmpty {
            addSeparator(to: menu)
            add(favoriteActions, to: menu, target: target, action: action)
        }

        if location.kind == .folder {
            addSeparator(to: menu)
            add([
                ("location.moveToTrash", "Move to Trash", .trash(url)),
            ], to: menu, target: target, action: action)
        }
    }

    private static func add(
        _ actions: [(identifier: String, title: String, action: BrowserAction)],
        to menu: NSMenu,
        target: AnyObject,
        action selector: Selector
    ) {
        for value in actions {
            let item = NSMenuItem(title: value.title, action: selector, keyEquivalent: "")
            item.target = target
            item.identifier = NSUserInterfaceItemIdentifier(value.identifier)
            item.representedObject = BrowserLocationContextMenuActionBox(value.action)
            menu.addItem(item)
        }
    }

    private static func addSeparator(to menu: NSMenu) {
        guard !menu.items.isEmpty, !menu.items.last!.isSeparatorItem else { return }
        menu.addItem(.separator())
    }
}

final class BrowserLocationContextMenuActionBox: NSObject {
    let action: BrowserAction

    init(_ action: BrowserAction) {
        self.action = action
    }
}
