import AppKit

/// Owns the lazy NSOutlineView presentation. Child discovery is delegated to
/// the application layer so this view controller never enumerates the disk.
@MainActor
final class BrowserSidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outlineView = NSOutlineView()
    var onSelection: ((BrowserSidebarLocation) -> Void)?
    var onExpansionRequest: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onCreateFolder: ((URL) -> Void)?
    var onMoveToTrash: ((URL) -> Void)?
    var onRemoveFavorite: ((URL) -> Void)?

    private var roots: [SidebarNode] = []
    private var requestedURLs = Set<URL>()

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar.location"))
        column.title = "Folders"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 13
        outlineView.backgroundColor = .clear
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.target = self
        outlineView.action = #selector(selectLocation(_:))
        outlineView.setAccessibilityLabel("Folder tree")

        let menu = NSMenu(title: "Folder")
        menu.delegate = self
        let open = NSMenuItem(title: "Open in New Tab", action: #selector(openInNewTab(_:)), keyEquivalent: "")
        open.target = self
        let create = NSMenuItem(title: "New Folder", action: #selector(createFolder(_:)), keyEquivalent: "")
        create.target = self
        let trash = NSMenuItem(title: "Move to Trash", action: #selector(moveToTrash(_:)), keyEquivalent: "")
        trash.target = self
        trash.identifier = NSUserInterfaceItemIdentifier("sidebar.moveToTrash")
        let remove = NSMenuItem(title: "Remove from Favorites", action: #selector(removeFavorite(_:)), keyEquivalent: "")
        remove.target = self
        remove.identifier = NSUserInterfaceItemIdentifier("sidebar.removeFavorite")
        menu.addItem(open)
        menu.addItem(create)
        let operationSeparator = NSMenuItem.separator()
        operationSeparator.identifier = NSUserInterfaceItemIdentifier("sidebar.operationSeparator")
        menu.addItem(operationSeparator)
        menu.addItem(trash)
        let favoriteSeparator = NSMenuItem.separator()
        favoriteSeparator.identifier = NSUserInterfaceItemIdentifier("sidebar.favoriteSeparator")
        menu.addItem(favoriteSeparator)
        menu.addItem(remove)
        outlineView.menu = menu
    }

    func displayRoots(_ locations: [BrowserSidebarLocation]) {
        let existing = Dictionary(uniqueKeysWithValues: roots.map { ($0.location.url, $0) })
        roots = locations.map { location in
            if let node = existing[location.url] {
                node.location = location
                return node
            }
            return SidebarNode(location: location)
        }
        outlineView.reloadData()
    }

    func displayChildren(_ locations: [BrowserSidebarLocation], for parentURL: URL) {
        guard let parent = findNode(parentURL.standardizedFileURL) else { return }
        let existing = Dictionary(uniqueKeysWithValues: (parent.children ?? []).map { ($0.location.url, $0) })
        parent.children = locations.map { location in
            if let node = existing[location.url] {
                node.location = location
                return node
            }
            return SidebarNode(location: location, parent: parent)
        }
        requestedURLs.remove(parentURL.standardizedFileURL)
        outlineView.reloadItem(parent, reloadChildren: true)
        if !(parent.children?.isEmpty ?? true) { outlineView.expandItem(parent) }
    }

    func reveal(_ url: URL) {
        guard let node = findNode(url.standardizedFileURL) else { return }
        var ancestor = node.parent
        while let current = ancestor {
            outlineView.expandItem(current)
            ancestor = current.parent
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func findNode(_ url: URL) -> SidebarNode? {
        func visit(_ nodes: [SidebarNode]) -> SidebarNode? {
            for node in nodes {
                if node.location.url == url { return node }
                if let children = node.children, let match = visit(children) { return match }
            }
            return nil
        }
        return visit(roots)
    }

    @objc private func selectLocation(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return }
        onSelection?(node.location)
    }

    @objc private func openInNewTab(_ sender: Any?) {
        guard let node = contextMenuNode else { return }
        onOpenInNewTab?(node.location.url)
    }

    @objc private func removeFavorite(_ sender: Any?) {
        guard let node = contextMenuNode, node.location.isRemovable else { return }
        onRemoveFavorite?(node.location.url)
    }

    @objc private func createFolder(_ sender: Any?) {
        guard let node = contextMenuNode else { return }
        onCreateFolder?(node.location.url)
    }

    @objc private func moveToTrash(_ sender: Any?) {
        guard let node = contextMenuNode, node.location.kind == .folder else { return }
        onMoveToTrash?(node.location.url)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = outlineView.clickedRow
        if clickedRow >= 0, !outlineView.selectedRowIndexes.contains(clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let canRemove = contextMenuNode?.location.isRemovable == true
        let canTrash = contextMenuNode?.location.kind == .folder
        menu.items.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("sidebar.removeFavorite")
        })?.isHidden = !canRemove
        menu.items.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("sidebar.favoriteSeparator")
        })?.isHidden = !canRemove
        menu.items.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("sidebar.moveToTrash")
        })?.isHidden = !canTrash
        menu.items.first(where: {
            $0.identifier == NSUserInterfaceItemIdentifier("sidebar.operationSeparator")
        })?.isHidden = !canTrash
    }

    private var contextMenuNode: SidebarNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SidebarNode
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children?.count ?? (item == nil ? roots.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? SidebarNode { return node.children![index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return node.children == nil || !(node.children?.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if node.children == nil, requestedURLs.insert(node.location.url).inserted {
            onExpansionRequest?(node.location.url)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar.cell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = node.location.title
        cell.textField?.toolTip = node.location.url.path
        let symbol: String
        switch node.location.kind {
        case .favorite: symbol = "star.fill"
        case .volume: symbol = "externaldrive.fill"
        case .folder: symbol = "folder"
        }
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: node.location.title)
        cell.imageView?.contentTintColor = .secondaryLabelColor
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

@MainActor
private final class SidebarNode: NSObject {
    var location: BrowserSidebarLocation
    weak var parent: SidebarNode?
    var children: [SidebarNode]?

    init(location: BrowserSidebarLocation, parent: SidebarNode? = nil) {
        self.location = location
        self.parent = parent
    }
}
