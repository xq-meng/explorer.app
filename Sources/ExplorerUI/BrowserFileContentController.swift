import AppKit

/// Owns the details and icon presentations for a folder's items.
///
/// The browser shell remains responsible for navigation, sidebar, search, and
/// preview layout. This component owns item rendering and interactions shared
/// by the two content modes: selection, sorting, rename, menus, and drag/drop.
@MainActor
final class BrowserFileContentController: NSViewController {
    var onOpenFileRow: ((BrowserFileRow) -> Void)?
    var onRenameSubmission: ((URL, String) -> Void)?
    var onSelectionChange: ((Set<URL>) -> Void)?
    var onSelectionPresentationChange: (([BrowserFileRow]) -> Void)?
    var onSortSelection: ((BrowserSortDescriptor) -> Void)?
    var onThumbnailRequest: ((URL) -> Void)?
    var onThumbnailCancellation: ((URL) -> Void)?
    var onFileCommand: ((BrowserFileCommand) -> Void)?
    var canPerformFileCommand: ((BrowserFileCommand) -> Bool)?
    var onFileURLDrop: ((BrowserFileDrop) -> Bool)?
    var onPromisedFileDrop: ((BrowserPromisedFileDrop) -> Bool)?
    var canAcceptFileURLDrop: (() -> Bool)?

    private let tableView = NSTableView()
    private let collectionView = BrowserDropCollectionView()
    private let listScrollView = NSScrollView()
    private let iconScrollView = NSScrollView()
    private let thumbnailCache = NSCache<NSURL, NSImage>()
    private var fileRows: [FileRow] = []
    private var viewMode: BrowserViewMode = .details
    private var sortDescriptor: BrowserSortDescriptor = .nameAscending
    private var renamingURL: URL?
    private var renameWasCancelled = false
    private var isApplyingSortDescriptor = false

    override func loadView() {
        thumbnailCache.countLimit = 256
        configureTableView()
        configureCollectionView()
        configureScrollViews()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listScrollView)
        container.addSubview(iconScrollView)
        for scrollView in [listScrollView, iconScrollView] {
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        view = container
        applySortDescriptor()
        updateViewMode()
    }

    func display(_ rows: [BrowserFileRow], selecting selectedURLs: Set<URL>) {
        loadViewIfNeeded()
        fileRows = rows.map(FileRow.init)
        tableView.reloadData()
        collectionView.reloadData()
        selectRows(with: selectedURLs)
        reportSelectionPresentation()
    }

    func beginRenaming(_ url: URL) {
        loadViewIfNeeded()
        let target = url.standardizedFileURL
        guard viewMode == .details,
              let row = fileRows.firstIndex(where: { $0.browserRow.url == target }),
              let column = tableView.tableColumns.firstIndex(where: {
                  $0.identifier.rawValue == "name"
              }) else { return }

        renamingURL = target
        renameWasCancelled = false
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: column)
        )

        DispatchQueue.main.async { [weak self] in
            guard let self, self.renamingURL == target,
                  let cell = self.tableView.view(
                    atColumn: column,
                    row: row,
                    makeIfNecessary: true
                  ) as? NSTableCellView,
                  let field = cell.textField else { return }
            field.isEditable = true
            field.isSelectable = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.isBezeled = true
            self.view.window?.makeFirstResponder(field)
            let name = field.stringValue as NSString
            let pathExtension = name.pathExtension as NSString
            let selectionLength = pathExtension.length == 0
                ? name.length
                : max(0, name.length - pathExtension.length - 1)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: selectionLength)
        }
    }

    func setViewMode(_ mode: BrowserViewMode) {
        guard isViewLoaded else {
            viewMode = mode
            return
        }
        let selectedIndexes = selectedItemIndexes
        viewMode = mode
        tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        collectionView.selectionIndexes = selectedIndexes
        updateViewMode()
        if mode == .icons {
            DispatchQueue.main.async { [weak self] in self?.requestVisibleThumbnails() }
        }
    }

    func setSortDescriptor(_ descriptor: BrowserSortDescriptor) {
        sortDescriptor = descriptor
        guard isViewLoaded else { return }
        applySortDescriptor()
    }

    func displayThumbnail(_ data: Data, for url: URL) {
        let target = url.standardizedFileURL
        guard let image = NSImage(data: data),
              let index = fileRows.firstIndex(where: { $0.browserRow.url == target }) else { return }
        thumbnailCache.setObject(image, forKey: target as NSURL)
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = collectionView.item(at: indexPath) as? BrowserIconCollectionItem else { return }
        item.display(fileRows[index].browserRow, thumbnail: image)
    }

    private func configureTableView() {
        [
            ("name", "Name", 250.0),
            ("size", "Size", 90.0),
            ("modified", "Date Modified", 150.0),
            ("kind", "Kind", 130.0),
        ].forEach { identifier, title, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 70
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .plain
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 26
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedFileRow(_:))
        tableView.setAccessibilityLabel("Folder contents")
        tableView.menu = makeFileContextMenu()
        tableView.registerForDraggedTypes(BrowserDropPasteboard.draggedTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 110, height: 100)
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        collectionView.collectionViewLayout = layout
        collectionView.register(
            BrowserIconCollectionItem.self,
            forItemWithIdentifier: BrowserIconCollectionItem.reuseIdentifier
        )
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.setAccessibilityLabel("Folder contents as icons")
        collectionView.menu = makeFileContextMenu()
        collectionView.registerForDraggedTypes(BrowserDropPasteboard.draggedTypes)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.onDrop = { [weak self] info, indexPath in
            guard let self else { return [] }
            return self.validateDrop(info, target: self.row(at: indexPath))
        }
        collectionView.onAcceptDrop = { [weak self] info, indexPath in
            guard let self else { return false }
            return self.acceptDrop(info, target: self.row(at: indexPath))
        }
    }

    private func configureScrollViews() {
        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.hasHorizontalScroller = true
        listScrollView.autohidesScrollers = true
        listScrollView.borderType = .noBorder
        listScrollView.setAccessibilityLabel("Folder contents")

        iconScrollView.documentView = collectionView
        iconScrollView.hasVerticalScroller = true
        iconScrollView.autohidesScrollers = true
        iconScrollView.borderType = .noBorder
        iconScrollView.setAccessibilityLabel("Folder contents as icons")
    }

    private func applySortDescriptor() {
        isApplyingSortDescriptor = true
        tableView.sortDescriptors = [NSSortDescriptor(
            key: sortDescriptor.field.rawValue,
            ascending: sortDescriptor.ascending
        )]
        isApplyingSortDescriptor = false
    }

    private func updateViewMode() {
        let showsIcons = viewMode == .icons
        listScrollView.isHidden = showsIcons
        iconScrollView.isHidden = !showsIcons
    }

    private func requestVisibleThumbnails() {
        guard viewMode == .icons else { return }
        collectionView.indexPathsForVisibleItems().forEach(requestThumbnailIfNeeded(at:))
    }

    private func requestThumbnailIfNeeded(at indexPath: IndexPath) {
        guard let row = row(at: indexPath), !row.isNavigable,
              thumbnailCache.object(forKey: row.url as NSURL) == nil else { return }
        onThumbnailRequest?(row.url)
    }

    private func row(at indexPath: IndexPath?) -> BrowserFileRow? {
        guard let index = indexPath?.item, fileRows.indices.contains(index) else { return nil }
        return fileRows[index].browserRow
    }

    private func selectRows(with urls: Set<URL>) {
        let indexes = IndexSet(fileRows.indices.filter { urls.contains(fileRows[$0].browserRow.url) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        collectionView.selectionIndexes = indexes
    }

    private func reportSelection() {
        let indexes = selectedItemIndexes
        if viewMode == .details {
            collectionView.selectionIndexes = indexes
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        reportSelectionPresentation()
        onSelectionChange?(Set(selectedRows.map(\.url)))
    }

    private func reportSelectionPresentation() {
        onSelectionPresentationChange?(selectedRows)
    }

    private var selectedRows: [BrowserFileRow] {
        selectedItemIndexes.compactMap { index in
            fileRows.indices.contains(index) ? fileRows[index].browserRow : nil
        }
    }

    private var selectedItemIndexes: IndexSet {
        viewMode == .details ? tableView.selectedRowIndexes : collectionView.selectionIndexes
    }

    @objc private func openSelectedFileRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard fileRows.indices.contains(row) else { return }
        onOpenFileRow?(fileRows[row].browserRow)
    }

    private func makeFileContextMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.delegate = self
        addContextItem("Open", command: .open, to: menu)
        addContextItem("Open in New Tab", command: .openInNewTab, to: menu)
        addContextItem("Show in Finder", command: .revealInFinder, to: menu)
        menu.addItem(.separator())
        addContextItem("New Folder", command: .newFolder, to: menu)
        menu.addItem(.separator())
        addContextItem("Rename", command: .rename, to: menu)
        addContextItem("Duplicate", command: .duplicate, to: menu)
        menu.addItem(.separator())
        addContextItem("Copy", command: .copy, to: menu)
        addContextItem("Cut", command: .cut, to: menu)
        addContextItem("Paste", command: .paste, to: menu)
        menu.addItem(.separator())
        addContextItem("Move to Trash", command: .moveToTrash, to: menu)
        menu.addItem(.separator())
        addContextItem("Quick Look", command: .quickLook, to: menu)
        return menu
    }

    private func addContextItem(_ title: String, command: BrowserFileCommand, to menu: NSMenu) {
        let item = NSMenuItem(
            title: title,
            action: #selector(performFileCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = FileCommandBox(command)
        menu.addItem(item)
    }

    @objc private func performFileCommand(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? FileCommandBox)?.command else { return }
        onFileCommand?(command)
    }

    private func validateDrop(_ info: NSDraggingInfo, target: BrowserFileRow?) -> NSDragOperation {
        guard canAcceptFileURLDrop?() == true,
              target?.isNavigable != false,
              BrowserDropPasteboard.canAccept(info.draggingPasteboard) else { return [] }
        return dropIntent(for: info) == .move ? .move : .copy
    }

    private func acceptDrop(_ info: NSDraggingInfo, target: BrowserFileRow?) -> Bool {
        let destination = target?.isNavigable == true ? target?.url : nil
        let intent = dropIntent(for: info)
        let payload = BrowserDropPasteboard.read(info.draggingPasteboard)
        if !payload.fileURLs.isEmpty {
            return onFileURLDrop?(BrowserFileDrop(
                urls: payload.fileURLs,
                destinationURL: destination,
                intent: intent
            )) ?? false
        }
        if !payload.promisedFileReceivers.isEmpty {
            return onPromisedFileDrop?(BrowserPromisedFileDrop(
                receivers: payload.promisedFileReceivers,
                destinationURL: destination,
                intent: intent
            )) ?? false
        }
        return false
    }

    private func dropIntent(for info: NSDraggingInfo) -> BrowserDropIntent {
        let source = info.draggingSource as AnyObject?
        let isInternal = source === tableView || source === collectionView
        let canMove = isInternal && info.draggingSourceOperationMask.contains(.move)
        return canMove && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    private func finishRenaming() {
        guard let source = renamingURL else { return }
        renamingURL = nil
        renameWasCancelled = false
        guard let row = fileRows.firstIndex(where: { $0.browserRow.url == source }),
              let column = tableView.tableColumns.firstIndex(where: {
                  $0.identifier.rawValue == "name"
              }) else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: column)
        )
    }
}

extension BrowserFileContentController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let source = renamingURL else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSubmit = !renameWasCancelled && !name.isEmpty && name != source.lastPathComponent
        finishRenaming()
        if shouldSubmit { onRenameSubmission?(source, name) }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard renamingURL != nil else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameWasCancelled = true
            view.window?.makeFirstResponder(tableView)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }
}

extension BrowserFileContentController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        fileRows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(
            "cell.\(tableColumn?.identifier.rawValue ?? "location")"
        )
        let isNameColumn = tableColumn?.identifier.rawValue == "name"
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeTableCell(identifier: identifier, showsIcon: isNameColumn)
        guard let label = cell.textField else { return cell }

        if let column = tableColumn {
            label.stringValue = fileRows[row].value(for: column.identifier.rawValue)
            label.setAccessibilityLabel("\(column.title): \(label.stringValue)")
            let isRenaming = isNameColumn && fileRows[row].browserRow.url == renamingURL
            label.delegate = isNameColumn ? self : nil
            label.isEditable = isRenaming
            label.isSelectable = isRenaming
            label.drawsBackground = isRenaming
            label.backgroundColor = isRenaming ? .textBackgroundColor : .clear
            label.isBezeled = isRenaming
            if isNameColumn, let icon = cell.imageView {
                icon.image = NSWorkspace.shared.icon(forFile: fileRows[row].browserRow.url.path)
                icon.imageScaling = .scaleProportionallyDown
            }
        }
        return cell
    }

    private func makeTableCell(
        identifier: NSUserInterfaceItemIdentifier,
        showsIcon: Bool
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        cell.textField = label
        cell.addSubview(label)

        if showsIcon {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = icon
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === tableView, viewMode == .details else { return }
        reportSelection()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === self.tableView, !isApplyingSortDescriptor,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let field = BrowserSortField(rawValue: key) else { return }
        onSortSelection?(BrowserSortDescriptor(field: field, ascending: descriptor.ascending))
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === self.tableView, fileRows.indices.contains(row) else { return nil }
        return fileRows[row].browserRow.url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === self.tableView else { return [] }
        let target = operation == .on && fileRows.indices.contains(row)
            ? fileRows[row].browserRow
            : nil
        if target?.isNavigable == true { tableView.setDropRow(row, dropOperation: .on) }
        return validateDrop(info, target: target)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        guard tableView === self.tableView else { return false }
        let target = operation == .on && fileRows.indices.contains(row)
            ? fileRows[row].browserRow
            : nil
        return acceptDrop(info, target: target)
    }
}

extension BrowserFileContentController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        fileRows.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: BrowserIconCollectionItem.reuseIdentifier,
            for: indexPath
        )
        guard let iconItem = item as? BrowserIconCollectionItem else { return item }
        let row = fileRows[indexPath.item].browserRow
        iconItem.display(row, thumbnail: thumbnailCache.object(forKey: row.url as NSURL))
        return iconItem
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard viewMode == .icons else { return }
        requestThumbnailIfNeeded(at: indexPath)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let url = (item as? BrowserIconCollectionItem)?.representedURL else { return }
        onThumbnailCancellation?(url)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        pasteboardWriterForItemAt indexPath: IndexPath
    ) -> NSPasteboardWriting? {
        guard fileRows.indices.contains(indexPath.item) else { return nil }
        return fileRows[indexPath.item].browserRow.url as NSURL
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard viewMode == .icons else { return }
        reportSelection()
        guard NSApp.currentEvent?.clickCount == 2,
              let index = indexPaths.first?.item,
              fileRows.indices.contains(index) else { return }
        onOpenFileRow?(fileRows[index].browserRow)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didDeselectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard viewMode == .icons else { return }
        reportSelection()
    }
}

extension BrowserFileContentController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        selectContextMenuTarget(for: menu)
        for item in menu.items {
            guard let command = (item.representedObject as? FileCommandBox)?.command else { continue }
            item.isEnabled = canPerformFileCommand?(command) ?? false
        }
    }

    private func selectContextMenuTarget(for menu: NSMenu) {
        if menu === tableView.menu {
            let row = tableView.clickedRow
            guard fileRows.indices.contains(row) else {
                tableView.deselectAll(nil)
                return
            }
            guard !tableView.selectedRowIndexes.contains(row) else { return }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }

        guard menu === collectionView.menu, let event = NSApp.currentEvent else { return }
        guard let indexPath = collectionView.indexPathForItem(
            at: collectionView.convert(event.locationInWindow, from: nil)
        ) else {
            collectionView.selectionIndexes = []
            reportSelection()
            return
        }
        guard fileRows.indices.contains(indexPath.item),
              !collectionView.selectionIndexes.contains(indexPath.item) else { return }
        collectionView.selectionIndexes = IndexSet(integer: indexPath.item)
        reportSelection()
    }
}

private final class FileCommandBox: NSObject {
    let command: BrowserFileCommand

    init(_ command: BrowserFileCommand) {
        self.command = command
    }
}
