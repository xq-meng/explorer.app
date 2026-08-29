import Foundation

public struct BrowserOpenWithApplication: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let isDefault: Bool

    public init(url: URL, name: String, isDefault: Bool) {
        self.url = url.standardizedFileURL
        self.name = name
        self.isDefault = isDefault
    }
}

public struct BrowserContextMenuState: Sendable, Equatable {
    public var hasSelection: Bool
    public var hasNavigableSelection: Bool
    public var isSingleSelection: Bool
    public var canPaste: Bool
    public var canAddToFavorites: Bool
    public var openWithApplications: [BrowserOpenWithApplication]

    public init(
        hasSelection: Bool,
        hasNavigableSelection: Bool,
        isSingleSelection: Bool,
        canPaste: Bool,
        canAddToFavorites: Bool,
        openWithApplications: [BrowserOpenWithApplication] = []
    ) {
        self.hasSelection = hasSelection
        self.hasNavigableSelection = hasNavigableSelection
        self.isSingleSelection = isSingleSelection
        self.canPaste = canPaste
        self.canAddToFavorites = canAddToFavorites
        self.openWithApplications = openWithApplications
    }

    public static let empty = BrowserContextMenuState(
        hasSelection: false,
        hasNavigableSelection: false,
        isSingleSelection: false,
        canPaste: false,
        canAddToFavorites: false
    )
}

public enum BrowserContextMenuItem: Sendable, Equatable {
    case command(BrowserFileCommand)
    case openWithMenu([BrowserOpenWithApplication])
    case navigation(BrowserNavigationCommand)
    case separator
}

public enum BrowserContextMenuBuilder {
    public static func items(for state: BrowserContextMenuState) -> [BrowserContextMenuItem] {
        collapsingSeparators(state.hasSelection ? selectionItems(state) : backgroundItems(state))
    }

    public static func title(for command: BrowserFileCommand) -> String {
        switch command {
        case .open: "Open"
        case .openInNewTab: "Open in New Tab"
        case .openWith: "Open With"
        case .revealInFinder: "Show in Finder"
        case .copyPath: "Copy Path"
        case .addToFavorites: "Add to Favorites"
        case .newFolder: "New Folder"
        case .rename: "Rename"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .duplicate: "Duplicate"
        case .moveToTrash: "Move to Trash"
        case .deletePermanently: "Delete Immediately…"
        case .quickLook: "Quick Look"
        }
    }

    public static func title(for command: BrowserNavigationCommand) -> String {
        switch command {
        case .back: "Back"
        case .forward: "Forward"
        case .up: "Enclosing Folder"
        case .refresh: "Refresh"
        }
    }

    public static func title(for application: BrowserOpenWithApplication) -> String {
        application.isDefault ? "\(application.name) (Default)" : application.name
    }

    private static func selectionItems(_ state: BrowserContextMenuState) -> [BrowserContextMenuItem] {
        var items: [BrowserContextMenuItem] = [.command(.open)]
        if !state.openWithApplications.isEmpty {
            items.append(.openWithMenu(state.openWithApplications))
        }
        if state.hasNavigableSelection {
            items.append(.command(.openInNewTab))
        }
        items.append(.command(.quickLook))
        items.append(.separator)
        items.append(.command(.revealInFinder))
        items.append(.command(.copyPath))
        if state.canAddToFavorites {
            items.append(.command(.addToFavorites))
        }
        items.append(.separator)
        if state.isSingleSelection {
            items.append(.command(.rename))
        }
        items.append(contentsOf: [.command(.duplicate), .command(.copy), .command(.cut)])
        items.append(.separator)
        items.append(.command(.moveToTrash))
        return items
    }

    private static func backgroundItems(_ state: BrowserContextMenuState) -> [BrowserContextMenuItem] {
        var items: [BrowserContextMenuItem] = [.command(.newFolder)]
        if state.canPaste {
            items.append(.command(.paste))
        }
        items.append(.separator)
        items.append(contentsOf: [
            .command(.copyPath),
            .command(.revealInFinder),
            .navigation(.refresh),
        ])
        return items
    }

    static func collapsingSeparators(_ items: [BrowserContextMenuItem]) -> [BrowserContextMenuItem] {
        var result: [BrowserContextMenuItem] = []
        for item in items {
            if case .separator = item {
                guard let last = result.last, last != .separator else { continue }
                result.append(item)
            } else {
                result.append(item)
            }
        }
        if case .separator = result.last {
            result.removeLast()
        }
        return result
    }
}
