import AppKit

/// The AppKit-first browser shell used by each Explorer window.
///
/// It contains presentation data only. Its callbacks make it straightforward
/// to attach navigation state and services without introducing filesystem
/// access into the view hierarchy.
@MainActor
public final class ExplorerBrowserViewController: NSViewController {
    public var onNavigationCommand: ((BrowserNavigationCommand) -> Void)?
    public var onViewModeSelection: ((BrowserViewMode) -> Void)?
    public var onSortSelection: ((BrowserSortDescriptor) -> Void)?
    public var onPathSubmission: ((String) -> Void)?
    public var onBreadcrumbSelection: ((URL) -> Void)?
    public var onSidebarLocationSelection: ((BrowserSidebarLocation) -> Void)?
    public var onSidebarExpansionRequest: ((URL) -> Void)?
    public var onOpenSidebarLocationInNewTab: ((URL) -> Void)?
    public var onCreateFolderInSidebarLocation: ((URL) -> Void)?
    public var onMoveSidebarLocationToTrash: ((URL) -> Void)?
    public var onRemoveSidebarFavorite: ((URL) -> Void)?
    public var onOpenFileRow: ((BrowserFileRow) -> Void)?
    public var onRenameSubmission: ((URL, String) -> Void)?
    public var onSelectionChange: ((Set<URL>) -> Void)?
    public var onSidebarWidthChange: ((CGFloat) -> Void)?
    public var onSearchQueryChange: ((String) -> Void)?
    public var onSearchClear: (() -> Void)?
    public var onThumbnailRequest: ((URL) -> Void)?
    public var onThumbnailCancellation: ((URL) -> Void)?
    public var onFileCommand: ((BrowserFileCommand) -> Void)?
    public var canPerformFileCommand: ((BrowserFileCommand) -> Bool)?
    public var onFileURLDrop: ((BrowserFileDrop) -> Bool)?
    public var canAcceptFileURLDrop: (() -> Bool)?

    private let breadcrumbBar = BrowserBreadcrumbBar()
    private let searchField = NSSearchField()
    private let viewModeControl = NSSegmentedControl()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let statusSummaryLabel = NSTextField(labelWithString: "0 items")
    private let fileTableView = NSTableView()
    private let collectionView = BrowserDropCollectionView()
    private let sidebarController = BrowserSidebarController()
    private let previewView = BrowserPreviewView()
    private var fileRows: [FileRow] = []
    private weak var splitView: NSSplitView?
    private weak var contentSplitView: NSSplitView?
    private weak var listScrollView: NSScrollView?
    private weak var iconScrollView: NSScrollView?
    private var renamingURL: URL?
    private var renameWasCancelled = false
    private var isApplyingSortDescriptor = false
    private let thumbnailCache = NSCache<NSURL, NSImage>()

    public private(set) var viewMode: BrowserViewMode = .details
    public private(set) var isPreviewVisible = true

    public override func loadView() {
        thumbnailCache.countLimit = 256
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let splitView = makeSplitView()
        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers?.lowercased() == "l", modifiers == .command {
            breadcrumbBar.focusAddressField()
            return true
        }
        guard event.charactersIgnoringModifiers == " ", modifiers.isEmpty,
              canPerformFileCommand?(.quickLook) == true else {
            return super.performKeyEquivalent(with: event)
        }
        onFileCommand?(.quickLook)
        return true
    }

    /// Updates the visible path after a navigation coordinator accepts it.
    public func displayPath(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        breadcrumbBar.display(url)
        sidebarController.reveal(url)
        showStatus("Showing \(path)")
    }

    /// Displays a brief accessibility-friendly status message in the footer.
    public func showStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.toolTip = message
        NSAccessibility.post(
            element: statusLabel,
            notification: .announcementRequested,
            userInfo: [NSAccessibility.NotificationUserInfoKey.announcement: message]
        )
    }

    /// Replaces the M0 rows when a directory snapshot becomes available.
    public func displayRows(_ rows: [BrowserFileRow], selecting selectedURLs: Set<URL> = []) {
        fileRows = rows.map(FileRow.init)
        fileTableView.reloadData()
        collectionView.reloadData()
        selectRows(with: selectedURLs)
        refreshSelectionPresentation()
    }

    /// Starts Windows Explorer-style editing in the Name column. Filesystem
    /// mutation remains owned by the app layer through `onRenameSubmission`.
    public func beginRenaming(_ url: URL) {
        let target = url.standardizedFileURL
        guard viewMode == .details,
              let row = fileRows.firstIndex(where: { $0.browserRow.url == target }),
              let column = fileTableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }

        renamingURL = target
        renameWasCancelled = false
        fileTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        fileTableView.scrollRowToVisible(row)
        fileTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))

        DispatchQueue.main.async { [weak self] in
            guard let self, self.renamingURL == target,
                  let cell = self.fileTableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            field.isEditable = true
            field.isSelectable = true
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.isBezeled = true
            self.view.window?.makeFirstResponder(field)
            let name = field.stringValue as NSString
            let pathExtension = (field.stringValue as NSString).pathExtension
            let selectionLength = pathExtension.isEmpty ? name.length : max(0, name.length - (pathExtension as NSString).length - 1)
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: selectionLength)
        }
    }

    public func setViewMode(_ mode: BrowserViewMode) {
        let selectedIndexes = viewMode == .details
            ? fileTableView.selectedRowIndexes
            : collectionView.selectionIndexes
        viewMode = mode
        viewModeControl.selectedSegment = mode == .icons ? 1 : 0
        fileTableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        collectionView.selectionIndexes = selectedIndexes
        updateViewMode()
        if mode == .icons {
            DispatchQueue.main.async { [weak self] in self?.requestVisibleThumbnails() }
        }
    }

    public func setSortDescriptor(_ descriptor: BrowserSortDescriptor) {
        isApplyingSortDescriptor = true
        fileTableView.sortDescriptors = [NSSortDescriptor(
            key: descriptor.field.rawValue,
            ascending: descriptor.ascending
        )]
        isApplyingSortDescriptor = false
    }

    public func displayThumbnail(_ data: Data, for url: URL) {
        let target = url.standardizedFileURL
        guard let image = NSImage(data: data),
              let index = fileRows.firstIndex(where: { $0.browserRow.url == target }) else { return }
        thumbnailCache.setObject(image, forKey: target as NSURL)
        let indexPath = IndexPath(item: index, section: 0)
        guard let item = collectionView.item(at: indexPath) as? BrowserIconCollectionItem else { return }
        item.display(fileRows[index].browserRow, thumbnail: image)
    }

    public func setPreviewVisible(_ isVisible: Bool) {
        isPreviewVisible = isVisible
        previewView.isHidden = !isVisible
        contentSplitView?.adjustSubviews()
    }

    /// Clears a per-tab query after navigation without making the UI layer
    /// decide how directory snapshots should be filtered.
    public func clearSearchField() {
        searchField.stringValue = ""
    }

    public func setSidebarWidth(_ width: CGFloat) {
        guard let splitView, splitView.subviews.count > 1 else { return }
        let position = max(180, min(380, width))
        splitView.setPosition(position, ofDividerAt: 0)
        DispatchQueue.main.async { [weak splitView] in
            splitView?.setPosition(position, ofDividerAt: 0)
        }
    }

    /// Supplies locations resolved by the application layer, rather than
    /// assuming that standard user folders exist on every Mac.
    public func displaySidebarLocations(_ locations: [BrowserSidebarLocation]) {
        sidebarController.displayRoots(locations)
    }

    /// Applies one lazily loaded level of the folder outline.
    public func displaySidebarChildren(_ locations: [BrowserSidebarLocation], for parentURL: URL) {
        sidebarController.displayChildren(locations, for: parentURL)
    }

    public func revealSidebarLocation(_ url: URL) {
        sidebarController.reveal(url)
    }

    private func makeSplitView() -> NSSplitView {
        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let sidebar = makeSidebar()
        let content = makeContentArea()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(content)
        let sidebarMinimum = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        let sidebarMaximum = sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        let contentMinimum = content.widthAnchor.constraint(greaterThanOrEqualToConstant: 520)
        sidebarMaximum.priority = .defaultHigh
        contentMinimum.priority = .defaultHigh
        NSLayoutConstraint.activate([sidebarMinimum, sidebarMaximum, contentMinimum])
        DispatchQueue.main.async { [weak splitView] in
            splitView?.setPosition(230, ofDividerAt: 0)
        }
        splitView.delegate = self
        self.splitView = splitView
        return splitView
    }

    private func makeSidebar() -> NSView {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .sidebar
        container.blendingMode = .withinWindow
        container.state = .active

        sidebarController.onSelection = { [weak self] location in
            self?.onSidebarLocationSelection?(location)
        }
        sidebarController.onExpansionRequest = { [weak self] url in
            self?.onSidebarExpansionRequest?(url)
        }
        sidebarController.onOpenInNewTab = { [weak self] url in
            self?.onOpenSidebarLocationInNewTab?(url)
        }
        sidebarController.onCreateFolder = { [weak self] url in
            self?.onCreateFolderInSidebarLocation?(url)
        }
        sidebarController.onMoveToTrash = { [weak self] url in
            self?.onMoveSidebarLocationToTrash?(url)
        }
        sidebarController.onRemoveFavorite = { [weak self] url in
            self?.onRemoveSidebarFavorite?(url)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = sidebarController.outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -3),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    private func makeContentArea() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        breadcrumbBar.onNavigate = { [weak self] url in self?.onBreadcrumbSelection?(url) }
        breadcrumbBar.onSubmitPath = { [weak self] path in self?.onPathSubmission?(path) }

        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(submitSearch(_:))
        searchField.setAccessibilityLabel("Filter current folder")
        searchField.setAccessibilityHelp("Filters the current folder by name.")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        viewModeControl.segmentCount = 2
        viewModeControl.trackingMode = .selectOne
        viewModeControl.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Details"), forSegment: 0)
        viewModeControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons"), forSegment: 1)
        viewModeControl.setToolTip("Details", forSegment: 0)
        viewModeControl.setToolTip("Icons", forSegment: 1)
        viewModeControl.selectedSegment = viewMode == .icons ? 1 : 0
        viewModeControl.target = self
        viewModeControl.action = #selector(changeViewMode(_:))
        viewModeControl.setAccessibilityLabel("View mode")

        configureFileTable()
        let tableScrollView = NSScrollView()
        tableScrollView.documentView = fileTableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .noBorder
        tableScrollView.setAccessibilityLabel("Folder contents")
        listScrollView = tableScrollView

        configureCollectionView()
        let iconScrollView = NSScrollView()
        iconScrollView.documentView = collectionView
        iconScrollView.hasVerticalScroller = true
        iconScrollView.autohidesScrollers = true
        iconScrollView.borderType = .noBorder
        iconScrollView.setAccessibilityLabel("Folder contents as icons")
        self.iconScrollView = iconScrollView

        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Folder status")
        statusSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        statusSummaryLabel.textColor = .secondaryLabelColor
        statusSummaryLabel.alignment = .right
        statusSummaryLabel.lineBreakMode = .byTruncatingHead
        statusSummaryLabel.setAccessibilityLabel("Folder item summary")

        let contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(tableScrollView)
        contentHost.addSubview(iconScrollView)
        for child in [tableScrollView, iconScrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                child.topAnchor.constraint(equalTo: contentHost.topAnchor),
                child.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }

        let browserSplitView = NSSplitView()
        browserSplitView.isVertical = true
        browserSplitView.dividerStyle = .thin
        browserSplitView.translatesAutoresizingMaskIntoConstraints = false
        browserSplitView.addArrangedSubview(contentHost)
        browserSplitView.addArrangedSubview(previewView)
        browserSplitView.delegate = self
        let contentMinimum = contentHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        let previewMinimum = previewView.widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        let previewMaximum = previewView.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        [contentMinimum, previewMinimum, previewMaximum].forEach { $0.priority = .defaultHigh; $0.isActive = true }
        contentSplitView = browserSplitView
        DispatchQueue.main.async { [weak browserSplitView] in
            guard let browserSplitView else { return }
            browserSplitView.setPosition(max(320, browserSplitView.bounds.width - 320), ofDividerAt: 0)
        }

        let navigation = NSStackView(views: [
            makeNavigationButton(symbol: "chevron.left", help: "Back", tag: 0),
            makeNavigationButton(symbol: "chevron.right", help: "Forward", tag: 1),
            makeNavigationButton(symbol: "arrow.up", help: "Up", tag: 2),
        ])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 1

        let topRow = NSStackView(views: [navigation, breadcrumbBar, searchField, viewModeControl])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 8
        topRow.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        let statusRow = NSStackView(views: [statusLabel, statusSummaryLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.distribution = .fill
        statusRow.spacing = 12
        statusRow.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        let stack = NSStackView(views: [topRow, browserSplitView, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            topRow.heightAnchor.constraint(equalToConstant: 42),
            browserSplitView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            browserSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 24),
            breadcrumbBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            statusSummaryLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        updateViewMode()
        return container
    }

    private func configureFileTable() {
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
            fileTableView.addTableColumn(column)
        }
        fileTableView.usesAlternatingRowBackgroundColors = true
        fileTableView.style = .plain
        fileTableView.allowsMultipleSelection = true
        fileTableView.rowHeight = 26
        fileTableView.delegate = self
        fileTableView.dataSource = self
        fileTableView.target = self
        fileTableView.doubleAction = #selector(openSelectedFileRow(_:))
        fileTableView.setAccessibilityLabel("Folder contents")
        fileTableView.menu = makeFileContextMenu()
        fileTableView.registerForDraggedTypes([.fileURL])
        fileTableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        fileTableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    }

    private func makeNavigationButton(symbol: String, help: String, tag: Int) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.bezelStyle = .inline
        button.isBordered = false
        button.tag = tag
        button.target = self
        button.action = #selector(performNavigation(_:))
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    @objc private func performNavigation(_ sender: NSButton) {
        let commands: [BrowserNavigationCommand] = [.back, .forward, .up]
        guard commands.indices.contains(sender.tag) else { return }
        onNavigationCommand?(commands[sender.tag])
    }

    @objc private func changeViewMode(_ sender: NSSegmentedControl) {
        onViewModeSelection?(sender.selectedSegment == 1 ? .icons : .details)
    }

    private func configureCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 110, height: 100)
        layout.sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        collectionView.collectionViewLayout = layout
        collectionView.register(BrowserIconCollectionItem.self, forItemWithIdentifier: BrowserIconCollectionItem.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.setAccessibilityLabel("Folder contents as icons")
        collectionView.menu = makeFileContextMenu()
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.onDrop = { [weak self] info, indexPath in
            guard let self else { return [] }
            let target = indexPath.flatMap { self.fileRows.indices.contains($0.item) ? self.fileRows[$0.item].browserRow : nil }
            return self.validateDrop(info, target: target)
        }
        collectionView.onAcceptDrop = { [weak self] info, indexPath in
            guard let self else { return false }
            let target = indexPath.flatMap { self.fileRows.indices.contains($0.item) ? self.fileRows[$0.item].browserRow : nil }
            return self.acceptDrop(info, target: target)
        }
    }

    private func updateViewMode() {
        let showsIcons = viewMode == .icons
        listScrollView?.isHidden = showsIcons
        iconScrollView?.isHidden = !showsIcons
    }

    private func requestVisibleThumbnails() {
        guard viewMode == .icons else { return }
        collectionView.indexPathsForVisibleItems().forEach(requestThumbnailIfNeeded(at:))
    }

    private func requestThumbnailIfNeeded(at indexPath: IndexPath) {
        guard fileRows.indices.contains(indexPath.item) else { return }
        let row = fileRows[indexPath.item].browserRow
        guard !row.isNavigable, thumbnailCache.object(forKey: row.url as NSURL) == nil else { return }
        onThumbnailRequest?(row.url)
    }

    private func selectRows(with urls: Set<URL>) {
        let indexes = IndexSet(fileRows.indices.filter { urls.contains(fileRows[$0].browserRow.url) })
        fileTableView.selectRowIndexes(indexes, byExtendingSelection: false)
        collectionView.selectionIndexes = indexes
    }

    private func reportSelection() {
        let indexes = viewMode == .details ? fileTableView.selectedRowIndexes : collectionView.selectionIndexes
        if viewMode == .details {
            collectionView.selectionIndexes = indexes
        } else {
            fileTableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
        let urls = Set(indexes.compactMap { index in
            fileRows.indices.contains(index) ? fileRows[index].browserRow.url : nil
        })
        refreshSelectionPresentation()
        onSelectionChange?(urls)
    }

    private func refreshSelectionPresentation() {
        let indexes = viewMode == .details ? fileTableView.selectedRowIndexes : collectionView.selectionIndexes
        let selectedRows = indexes.compactMap { index in
            fileRows.indices.contains(index) ? fileRows[index].browserRow : nil
        }
        previewView.display(selectedRows)

        var components: [String] = []
        if !selectedRows.isEmpty {
            components.append("\(selectedRows.count) selected")
            let selectedBytes = selectedRows.compactMap(\.sizeInBytes).reduce(0, +)
            if selectedBytes > 0 {
                components.append(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))
            }
        }
        statusSummaryLabel.stringValue = components.joined(separator: "  ·  ")
    }

    @objc private func openSelectedFileRow(_ sender: Any?) {
        let row = fileTableView.clickedRow
        guard fileRows.indices.contains(row) else { return }
        onOpenFileRow?(fileRows[row].browserRow)
    }

    @objc private func submitSearch(_ sender: Any?) {
        notifySearchChange()
    }

    private func notifySearchChange() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            onSearchClear?()
        } else {
            onSearchQueryChange?(query)
        }
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
        let item = NSMenuItem(title: title, action: #selector(performFileCommand(_:)), keyEquivalent: "")
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
              !droppedFileURLs(from: info).isEmpty else { return [] }
        return dropIntent(for: info) == .move ? .move : .copy
    }

    private func acceptDrop(_ info: NSDraggingInfo, target: BrowserFileRow?) -> Bool {
        let urls = droppedFileURLs(from: info)
        guard !urls.isEmpty else { return false }
        return onFileURLDrop?(BrowserFileDrop(
            urls: urls,
            destinationURL: target?.isNavigable == true ? target?.url : nil,
            intent: dropIntent(for: info)
        )) ?? false
    }

    private func droppedFileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }

    private func dropIntent(for info: NSDraggingInfo) -> BrowserDropIntent {
        let source = info.draggingSource as AnyObject?
        let isInternal = source === fileTableView || source === collectionView
        let canMove = isInternal && info.draggingSourceOperationMask.contains(.move)
        return canMove && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

}

extension ExplorerBrowserViewController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        notifySearchChange()
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              !(field is NSSearchField),
              let source = renamingURL else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSubmit = !renameWasCancelled && !name.isEmpty && name != source.lastPathComponent
        finishRenaming()
        if shouldSubmit { onRenameSubmission?(source, name) }
    }

    public func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control is NSTextField, control !== searchField, renamingURL != nil else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameWasCancelled = true
            view.window?.makeFirstResponder(fileTableView)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(fileTableView)
            return true
        }
        return false
    }

    private func finishRenaming() {
        guard let source = renamingURL else { return }
        renamingURL = nil
        renameWasCancelled = false
        guard let row = fileRows.firstIndex(where: { $0.browserRow.url == source }),
              let column = fileTableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) else { return }
        fileTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
    }
}

extension ExplorerBrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        fileRows.count
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell.\(tableColumn?.identifier.rawValue ?? "location")")
        let isNameColumn = tableColumn?.identifier.rawValue == "name"
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeFileTableCell(identifier: identifier, showsIcon: isNameColumn)
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

    private func makeFileTableCell(
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

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === fileTableView, viewMode == .details else { return }
        reportSelection()
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === fileTableView, !isApplyingSortDescriptor,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let field = BrowserSortField(rawValue: key) else { return }
        onSortSelection?(BrowserSortDescriptor(field: field, ascending: descriptor.ascending))
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === fileTableView, fileRows.indices.contains(row) else { return nil }
        return fileRows[row].browserRow.url as NSURL
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === fileTableView else { return [] }
        let target = operation == .on && fileRows.indices.contains(row) ? fileRows[row].browserRow : nil
        if target?.isNavigable == true { tableView.setDropRow(row, dropOperation: .on) }
        return validateDrop(info, target: target)
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        guard tableView === fileTableView else { return false }
        let target = operation == .on && fileRows.indices.contains(row) ? fileRows[row].browserRow : nil
        return acceptDrop(info, target: target)
    }
}

extension ExplorerBrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        fileRows.count
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: BrowserIconCollectionItem.reuseIdentifier, for: indexPath)
        guard let iconItem = item as? BrowserIconCollectionItem else { return item }
        let row = fileRows[indexPath.item].browserRow
        iconItem.display(row, thumbnail: thumbnailCache.object(forKey: row.url as NSURL))
        return iconItem
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard viewMode == .icons else { return }
        requestThumbnailIfNeeded(at: indexPath)
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        guard let url = (item as? BrowserIconCollectionItem)?.representedURL else { return }
        onThumbnailCancellation?(url)
    }

    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard fileRows.indices.contains(indexPath.item) else { return nil }
        return fileRows[indexPath.item].browserRow.url as NSURL
    }

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard viewMode == .icons else { return }
        reportSelection()
        guard NSApp.currentEvent?.clickCount == 2,
              let index = indexPaths.first?.item,
              fileRows.indices.contains(index) else { return }
        onOpenFileRow?(fileRows[index].browserRow)
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard viewMode == .icons else { return }
        reportSelection()
    }
}

extension ExplorerBrowserViewController: NSSplitViewDelegate {
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView, splitView.subviews.count > 1 else { return }
        onSidebarWidthChange?(splitView.subviews[0].frame.width)
    }
}

extension ExplorerBrowserViewController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        selectContextMenuTarget(for: menu)
        for item in menu.items {
            guard let command = (item.representedObject as? FileCommandBox)?.command else { continue }
            item.isEnabled = canPerformFileCommand?(command) ?? false
        }
    }

    private func selectContextMenuTarget(for menu: NSMenu) {
        if menu === fileTableView.menu {
            let row = fileTableView.clickedRow
            guard fileRows.indices.contains(row) else {
                fileTableView.deselectAll(nil)
                return
            }
            guard !fileTableView.selectedRowIndexes.contains(row) else { return }
            fileTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
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
        guard
              fileRows.indices.contains(indexPath.item),
              !collectionView.selectionIndexes.contains(indexPath.item) else { return }
        collectionView.selectionIndexes = IndexSet(integer: indexPath.item)
        reportSelection()
    }
}

private final class FileCommandBox: NSObject {
    let command: BrowserFileCommand
    init(_ command: BrowserFileCommand) { self.command = command }
}
