import AppKit

/// Owns the source-list of folder shortcuts. Clicking an item opens that
/// location in the main pane; the sidebar never expands into a directory tree.
@MainActor
final class BrowserSidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outlineView = NSOutlineView()
    var onAction: ((BrowserAction) -> Void)?
    var viewState = BrowserViewState.empty

    private var groups: [SidebarGroup] = []

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
        outlineView.setAccessibilityLabel("Places")

        let menu = NSMenu(title: "Folder")
        menu.delegate = self
        menu.autoenablesItems = false
        outlineView.menu = menu
    }

    func displayRoots(_ locations: [BrowserSidebarLocation]) {
        let selectedLocation = (outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode)?.location.location
        let existingNodes = Dictionary(uniqueKeysWithValues: groups
            .flatMap(\.children)
            .map { ($0.location.location, $0) })
        let existingGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.section, $0) })

        groups = SidebarSection.allCases.compactMap { section in
            let sectionLocations = locations.filter { section.contains($0.kind) }
            guard !sectionLocations.isEmpty else { return nil }
            let group = existingGroups[section] ?? SidebarGroup(section: section)
            group.children = sectionLocations.map { location in
                if let node = existingNodes[location.location] {
                    node.location = location
                    return node
                }
                return SidebarNode(location: location)
            }
            return group
        }
        outlineView.reloadData()
        groups.forEach { outlineView.expandItem($0) }
        if let selectedLocation {
            select(selectedLocation)
        }
    }

    func select(_ location: BrowserLocation?) {
        guard let location, let node = findNode(location) else {
            outlineView.deselectAll(nil)
            return
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        let action = outlineView.action
        outlineView.action = nil
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        outlineView.action = action
    }

    private func findNode(_ location: BrowserLocation) -> SidebarNode? {
        groups.flatMap(\.children).first { $0.location.location == location }
    }

    @objc private func selectLocation(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode else { return }
        emit(.openLocation(node.location.location))
    }


    @objc private func performContextMenuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? BrowserLocationContextMenuActionBox)?.action else {
            return
        }
        emit(action)
    }

    private func emit(_ action: BrowserAction) {
        onAction?(action)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = outlineView.clickedRow
        if clickedRow >= 0, !outlineView.selectedRowIndexes.contains(clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        guard let location = contextMenuNode?.location else {
            menu.removeAllItems()
            return
        }
        BrowserLocationContextMenuBuilder.rebuild(
            menu,
            for: location,
            viewState: viewState,
            target: self,
            action: #selector(performContextMenuAction(_:))
        )
    }

    private var contextMenuNode: SidebarNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? SidebarNode
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? SidebarGroup { return group.children.count }
        return item == nil ? groups.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? SidebarGroup { return group.children[index] }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let reused = outlineView.makeView(
            withIdentifier: BrowserFileTableRowView.reuseIdentifier,
            owner: self
        ) as? BrowserFileTableRowView {
            reused.resetHover()
            reused.selectionHighlightStyle = outlineView.selectionHighlightStyle
            return reused
        }
        let rowView = BrowserFileTableRowView()
        rowView.identifier = BrowserFileTableRowView.reuseIdentifier
        rowView.selectionHighlightStyle = outlineView.selectionHighlightStyle
        return rowView
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        didRemove rowView: NSTableRowView,
        forRow row: Int
    ) {
        (rowView as? BrowserFileTableRowView)?.resetHover()
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
        cell.textField?.toolTip = node.location.directoryURL?.path ?? node.location.title
        let icon = sidebarIcon(for: node.location)
        cell.imageView?.image = icon.image
        cell.imageView?.contentTintColor = icon.isTemplate ? .secondaryLabelColor : nil
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SidebarGroup
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarNode
    }

    private func sidebarIcon(for location: BrowserSidebarLocation) -> (image: NSImage?, isTemplate: Bool) {
        switch location.kind {
        case .computer:
            return (
                NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: location.title),
                true
            )
        case .volume:
            return (
                NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: location.title),
                true
            )
        case .folder:
            return (
                NSImage(systemSymbolName: "folder", accessibilityDescription: location.title),
                true
            )
        case .favorite:
            if !location.isRemovable, let url = location.directoryURL {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                image.size = NSSize(width: 16, height: 16)
                image.isTemplate = false
                return (image, false)
            }
            return (
                NSImage(systemSymbolName: "folder", accessibilityDescription: location.title),
                true
            )
        case .network:
            let symbol = location.directoryURL?.path.contains("com~apple~CloudDocs") == true
                ? "icloud.fill"
                : "network"
            return (
                NSImage(systemSymbolName: symbol, accessibilityDescription: location.title),
                true
            )
        }
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
    case network
    case folders

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .volumes: "Volumes"
        case .network: "Network"
        case .folders: "Folders"
        }
    }

    func contains(_ kind: BrowserSidebarLocationKind) -> Bool {
        switch (self, kind) {
        case (.favorites, .favorite), (.favorites, .computer),
             (.volumes, .volume), (.network, .network), (.folders, .folder): true
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

    init(location: BrowserSidebarLocation) {
        self.location = location
    }
}
