import AppKit

/// The AppKit-first browser shell used by each Explorer window.
///
/// It owns navigation, sidebar, search, status, and preview layout. File-item
/// rendering and interaction are delegated to ``BrowserFileContentController``.
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
    public var onAddSidebarFavorite: ((URL) -> Void)?
    public var onCopySidebarPath: ((URL) -> Void)?
    public var onRevealSidebarInFinder: ((URL) -> Void)?
    public var canAddSidebarFavorite: ((URL) -> Bool)?
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
    public var contextMenuState: (() -> BrowserContextMenuState)?
    public var onFileURLDrop: ((BrowserFileDrop) -> Bool)?
    public var onPromisedFileDrop: ((BrowserPromisedFileDrop) -> Bool)?
    public var canAcceptFileURLDrop: (() -> Bool)?

    private let breadcrumbBar = BrowserBreadcrumbBar()
    private let searchField = NSSearchField()
    private let viewModeControl = NSSegmentedControl()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let statusSummaryLabel = NSTextField(labelWithString: "0 items")
    private let sidebarController = BrowserSidebarController()
    private let previewView = BrowserPreviewView()
    private lazy var fileContentController: BrowserFileContentController = {
        let controller = BrowserFileContentController()
        controller.onOpenFileRow = { [weak self] row in self?.onOpenFileRow?(row) }
        controller.onRenameSubmission = { [weak self] url, name in
            self?.onRenameSubmission?(url, name)
        }
        controller.onSelectionChange = { [weak self] urls in self?.onSelectionChange?(urls) }
        controller.onSelectionPresentationChange = { [weak self] rows in
            self?.displaySelection(rows)
        }
        controller.onSortSelection = { [weak self] descriptor in
            self?.onSortSelection?(descriptor)
        }
        controller.onThumbnailRequest = { [weak self] url in self?.onThumbnailRequest?(url) }
        controller.onThumbnailCancellation = { [weak self] url in
            self?.onThumbnailCancellation?(url)
        }
        controller.onFileCommand = { [weak self] command in self?.onFileCommand?(command) }
        controller.onNavigationCommand = { [weak self] command in
            self?.onNavigationCommand?(command)
        }
        controller.contextMenuState = { [weak self] in
            self?.contextMenuState?() ?? .empty
        }
        controller.onFileURLDrop = { [weak self] drop in self?.onFileURLDrop?(drop) ?? false }
        controller.onPromisedFileDrop = { [weak self] drop in
            self?.onPromisedFileDrop?(drop) ?? false
        }
        controller.canAcceptFileURLDrop = { [weak self] in
            self?.canAcceptFileURLDrop?() ?? false
        }
        return controller
    }()
    private weak var splitView: NSSplitView?
    private weak var contentSplitView: NSSplitView?
    private var requestedSidebarWidth: CGFloat = SidebarLayout.defaultWidth
    private var sidebarWidthUpdateGeneration = 0
    private var canReportSidebarWidth = false
    private var isApplyingSidebarWidth = false
    private var previewPaneWidth: CGFloat = 320
    private var previewVisibilityGeneration = 0

    public private(set) var viewMode: BrowserViewMode = .details
    public private(set) var isPreviewVisible = true

    public override func loadView() {
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
        breadcrumbBar.display(URL(fileURLWithPath: path).standardizedFileURL)
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

    public func displayRows(_ rows: [BrowserFileRow], selecting selectedURLs: Set<URL> = []) {
        fileContentController.display(rows, selecting: selectedURLs)
    }

    public func setCutURLs(_ urls: Set<URL>) {
        fileContentController.setCutURLs(urls)
    }

    public func beginRenaming(_ url: URL) {
        fileContentController.beginRenaming(url)
    }

    public func setViewMode(_ mode: BrowserViewMode) {
        viewMode = mode
        viewModeControl.selectedSegment = mode == .icons ? 1 : 0
        fileContentController.setViewMode(mode)
    }

    public func setSortDescriptor(_ descriptor: BrowserSortDescriptor) {
        fileContentController.setSortDescriptor(descriptor)
    }

    public func displayThumbnail(_ data: Data, for url: URL) {
        fileContentController.displayThumbnail(data, for: url)
    }

    public func setPreviewVisible(_ isVisible: Bool) {
        isPreviewVisible = isVisible
        previewVisibilityGeneration &+= 1
        guard let contentSplitView else {
            previewView.isHidden = !isVisible
            return
        }

        if isVisible {
            previewView.isHidden = false
            if previewView.superview !== contentSplitView {
                contentSplitView.addArrangedSubview(previewView)
            }
            positionPreviewPane(in: contentSplitView)
        } else {
            if previewView.frame.width > 0 {
                previewPaneWidth = min(420, max(210, previewView.frame.width))
            }
            previewView.removeFromSuperview()
            previewView.isHidden = true
            contentSplitView.adjustSubviews()
        }
    }

    public func clearSearchField() {
        searchField.stringValue = ""
    }

    public func setSidebarWidth(_ width: CGFloat) {
        requestedSidebarWidth = min(
            SidebarLayout.maximumWidth,
            max(SidebarLayout.minimumWidth, width)
        )
        sidebarWidthUpdateGeneration &+= 1
        let generation = sidebarWidthUpdateGeneration
        guard let splitView, splitView.subviews.count > 1 else { return }
        applySidebarWidth(to: splitView)
        DispatchQueue.main.async { [weak self, weak splitView] in
            guard let self, let splitView,
                  generation == self.sidebarWidthUpdateGeneration else { return }
            self.applySidebarWidth(to: splitView)
            self.canReportSidebarWidth = true
        }
    }

    public func displaySidebarLocations(_ locations: [BrowserSidebarLocation]) {
        sidebarController.displayRoots(locations)
    }

    public func displaySidebarChildren(
        _ locations: [BrowserSidebarLocation],
        for parentURL: URL
    ) {
        sidebarController.displayChildren(locations, for: parentURL)
    }

    private func displaySelection(_ rows: [BrowserFileRow]) {
        previewView.display(rows)
        var components: [String] = []
        if !rows.isEmpty {
            components.append("\(rows.count) selected")
            let selectedBytes = rows.compactMap(\.sizeInBytes).reduce(0, +)
            if selectedBytes > 0 {
                components.append(ByteCountFormatter.string(
                    fromByteCount: selectedBytes,
                    countStyle: .file
                ))
            }
        }
        statusSummaryLabel.stringValue = components.joined(separator: "  ·  ")
    }

    private func positionPreviewPane(in splitView: NSSplitView) {
        let generation = previewVisibilityGeneration
        applyPreviewPanePosition(in: splitView, generation: generation)
        DispatchQueue.main.async { [weak self, weak splitView] in
            guard let self, let splitView else { return }
            self.applyPreviewPanePosition(in: splitView, generation: generation)
        }
    }

    private func applyPreviewPanePosition(in splitView: NSSplitView, generation: Int) {
        guard isPreviewVisible, previewView.superview === splitView,
              generation == previewVisibilityGeneration else { return }
        splitView.setPosition(max(300, splitView.bounds.width - previewPaneWidth), ofDividerAt: 0)
    }

    private func applySidebarWidth(to splitView: NSSplitView) {
        isApplyingSidebarWidth = true
        splitView.setPosition(requestedSidebarWidth, ofDividerAt: 0)
        isApplyingSidebarWidth = false
    }

    private func makeSplitView() -> NSSplitView {
        let splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(makeSidebar())
        splitView.addArrangedSubview(makeContentArea())
        splitView.delegate = self
        self.splitView = splitView
        setSidebarWidth(requestedSidebarWidth)
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
        sidebarController.onAddFavorite = { [weak self] url in
            self?.onAddSidebarFavorite?(url)
        }
        sidebarController.onCopyPath = { [weak self] url in
            self?.onCopySidebarPath?(url)
        }
        sidebarController.onRevealInFinder = { [weak self] url in
            self?.onRevealSidebarInFinder?(url)
        }
        sidebarController.canAddFavorite = { [weak self] url in
            self?.canAddSidebarFavorite?(url) ?? false
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
        configureSearchField()
        configureViewModeControl()
        configureStatusLabels()

        if fileContentController.parent !== self {
            addChild(fileContentController)
        }
        let contentView = fileContentController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let browserSplitView = NSSplitView()
        browserSplitView.isVertical = true
        browserSplitView.dividerStyle = .thin
        browserSplitView.translatesAutoresizingMaskIntoConstraints = false
        browserSplitView.addArrangedSubview(contentView)
        if isPreviewVisible {
            browserSplitView.addArrangedSubview(previewView)
        }
        browserSplitView.delegate = self
        let contentMinimum = contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
        let previewMinimum = previewView.widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        let previewMaximum = previewView.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        [contentMinimum, previewMinimum, previewMaximum].forEach {
            $0.priority = .defaultHigh
            $0.isActive = true
        }
        contentSplitView = browserSplitView
        previewView.isHidden = !isPreviewVisible
        if isPreviewVisible { positionPreviewPane(in: browserSplitView) }

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
        return container
    }

    private func configureSearchField() {
        searchField.placeholderString = "Search"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(submitSearch(_:))
        searchField.setAccessibilityLabel("Search this folder")
        searchField.setAccessibilityHelp("Searches the current folder and its subfolders by name.")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    private func configureViewModeControl() {
        viewModeControl.segmentCount = 2
        viewModeControl.trackingMode = .selectOne
        viewModeControl.setImage(
            NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Details"),
            forSegment: 0
        )
        viewModeControl.setImage(
            NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Icons"),
            forSegment: 1
        )
        viewModeControl.setToolTip("Details", forSegment: 0)
        viewModeControl.setToolTip("Icons", forSegment: 1)
        viewModeControl.selectedSegment = viewMode == .icons ? 1 : 0
        viewModeControl.target = self
        viewModeControl.action = #selector(changeViewMode(_:))
        viewModeControl.setAccessibilityLabel("View mode")
    }

    private func configureStatusLabels() {
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("Folder status")
        statusSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        statusSummaryLabel.textColor = .secondaryLabelColor
        statusSummaryLabel.alignment = .right
        statusSummaryLabel.lineBreakMode = .byTruncatingHead
        statusSummaryLabel.setAccessibilityLabel("Folder item summary")
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
}

extension ExplorerBrowserViewController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        notifySearchChange()
    }
}

extension ExplorerBrowserViewController: NSSplitViewDelegate {
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard canReportSidebarWidth, !isApplyingSidebarWidth,
              let splitView, splitView.subviews.count > 1 else { return }
        let width = splitView.subviews[0].frame.width
        guard width >= SidebarLayout.minimumWidth,
              width <= SidebarLayout.maximumWidth else { return }
        requestedSidebarWidth = width
        onSidebarWidthChange?(width)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView, dividerIndex == 0 else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, SidebarLayout.minimumWidth)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView, dividerIndex == 0 else { return proposedMaximumPosition }
        let contentLimitedWidth = max(
            SidebarLayout.minimumWidth,
            splitView.bounds.width - SidebarLayout.minimumContentWidth - splitView.dividerThickness
        )
        return min(proposedMaximumPosition, SidebarLayout.maximumWidth, contentLimitedWidth)
    }

    public func splitView(
        _ splitView: NSSplitView,
        shouldAdjustSizeOfSubview view: NSView
    ) -> Bool {
        guard splitView === self.splitView,
              let sidebar = splitView.subviews.first else { return true }
        return view !== sidebar
    }
}

private enum SidebarLayout {
    static let defaultWidth: CGFloat = 176
    static let minimumWidth: CGFloat = 148
    static let maximumWidth: CGFloat = 300
    static let minimumContentWidth: CGFloat = 480
}
