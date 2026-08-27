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

    private var groups: [SidebarGroup] = []
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
        let existingNodes = Dictionary(uniqueKeysWithValues: groups
            .flatMap(\.children)
            .map { ($0.location.url, $0) })
        let existingGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.section, $0) })

        groups = SidebarSection.allCases.compactMap { section in
            let sectionLocations = locations.filter { section.contains($0.kind) }
            guard !sectionLocations.isEmpty else { return nil }
            let group = existingGroups[section] ?? SidebarGroup(section: section)
            group.children = sectionLocations.map { location in
                if let node = existingNodes[location.url] {
                    node.location = location
                    node.parent = nil
                    return node
                }
                return SidebarNode(location: location)
            }
            return group
        }
        outlineView.reloadData()
        groups.forEach { outlineView.expandItem($0) }
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

    private func findNode(_ url: URL) -> SidebarNode? {
        func visit(_ nodes: [SidebarNode]) -> SidebarNode? {
            for node in nodes {
                if node.location.url == url { return node }
                if let children = node.children, let match = visit(children) { return match }
            }
            return nil
        }
        return visit(groups.flatMap(\.children))
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
        if let group = item as? SidebarGroup { return group.children.count }
        if let node = item as? SidebarNode { return node.children?.count ?? 0 }
        return item == nil ? groups.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? SidebarGroup { return group.children[index] }
        if let node = item as? SidebarNode { return node.children![index] }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is SidebarGroup { return true }
        guard let node = item as? SidebarNode else { return false }
        return node.children == nil || !(node.children?.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if item is SidebarGroup { return true }
        guard let node = item as? SidebarNode else { return false }
        if node.children == nil, requestedURLs.insert(node.location.url).inserted {
            onExpansionRequest?(node.location.url)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SidebarGroup {
            let identifier = NSUserInterfaceItemIdentifier("sidebar.group")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
                ?? makeGroupCell(identifier: identifier)
            cell.textField?.stringValue = group.section.title
            return cell
        }
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

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarNode
    }

    private func makeGroupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
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

private enum SidebarSection: Int, CaseIterable {
    case favorites
    case volumes
    case folders

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .volumes: "Volumes"
        case .folders: "Folders"
        }
    }

    func contains(_ kind: BrowserSidebarLocationKind) -> Bool {
        switch (self, kind) {
        case (.favorites, .favorite), (.volumes, .volume), (.folders, .folder): true
        default: false
        }
    }
}

@MainActor
private final class SidebarGroup: NSObject {
    let section: SidebarSection
    var children: [SidebarNode] = []

    init(section: SidebarSection) {
        self.section = section
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
