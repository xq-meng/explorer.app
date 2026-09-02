import AppKit

/// The AppKit-first browser shell used by each Explorer window.
///
/// It owns navigation, sidebar, search, status, and preview layout. File-item
/// rendering and interaction are delegated to ``BrowserFileContentController``.
@MainActor
public final class ExplorerBrowserViewController: NSViewController {
    /// Single event outlet. The return value is used only for drop actions.
    public var onAction: ((BrowserAction) -> Bool)?
    public var onActivate: (() -> Void)?
    public var viewState = BrowserViewState.empty {
        didSet { applyViewState() }
    }

    private let breadcrumbBar = BrowserBreadcrumbBar()
    private let searchField = NSSearchField()
    private let viewModeControl = NSSegmentedControl()
    private let dualPaneButton = BrowserToolbarButton()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let statusSummaryLabel = NSTextField(labelWithString: "0 items")
    private let sidebarController = BrowserSidebarController()
    private let previewView = BrowserPreviewView()
    private let activePaneIndicator = NSView()
    private lazy var homePageController: BrowserHomePageController = {
        let controller = BrowserHomePageController()
        controller.onAction = { [weak self] action in
            _ = self?.emit(action)
        }
        return controller
    }()
    private lazy var fileContentController: BrowserFileContentController = {
        let controller = BrowserFileContentController()
        controller.viewState = viewState
        controller.onAction = { [weak self] action in
            self?.emit(action) ?? false
        }
        controller.onSelectionPresentationChange = { [weak self] rows in
            self?.displaySelection(rows)
        }
        controller.onActivate = { [weak self] in self?.onActivate?() }
        return controller
    }()
    private weak var splitView: NSSplitView?
    private weak var contentSplitView: NSSplitView?
    private var sidebarView: NSView?
    private var requestedSidebarWidth: CGFloat = SidebarLayout.defaultWidth
    private var sidebarWidthUpdateGeneration = 0
    private var canReportSidebarWidth = false
    private var isApplyingSidebarWidth = false
    private var previewPaneWidth: CGFloat = 320
    private var previewVisibilityGeneration = 0

    public private(set) var viewMode: BrowserViewMode = .details
    public private(set) var isPreviewVisible = true
    public private(set) var isSidebarVisible: Bool
    public private(set) var isPaneActive = false

    public init(showsSidebar: Bool = true) {
        isSidebarVisible = showsSidebar
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let splitView = makeSplitView()
        view.addSubview(splitView)
        activePaneIndicator.translatesAutoresizingMaskIntoConstraints = false
        activePaneIndicator.wantsLayer = true
        activePaneIndicator.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.65)
            .cgColor
        activePaneIndicator.layer?.cornerRadius = 1
        activePaneIndicator.isHidden = true
        view.addSubview(activePaneIndicator)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activePaneIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            activePaneIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            activePaneIndicator.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            activePaneIndicator.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers?.lowercased() == "l", modifiers == .command {
            breadcrumbBar.focusAddressField()
            return true
        }
        guard event.charactersIgnoringModifiers == " ", modifiers.isEmpty,
              viewState.canPerform(.quickLook) else {
            return super.performKeyEquivalent(with: event)
        }
        _ = emit(.file(.quickLook))
        return true
    }

    /// Updates the visible location after a navigation coordinator accepts it.
    public func displayLocation(_ location: BrowserLocation, trail: [BrowserPathComponent]? = nil) {
        breadcrumbBar.display(location, trail: trail)
        if let url = location.directoryURL {
            showStatus("Showing \(url.path)")
        }
    }

    public func beginLeavingHomePage(loading location: BrowserLocation) {
        homePageController.view.isHidden = true
        fileContentController.view.isHidden = false
        fileContentController.display([], selecting: [])
        setViewModeControlVisible(true)
        breadcrumbBar.display(location, trail: nil)
        if let url = location.directoryURL {
            showStatus("Loading \(url.path)…")
        } else {
            showStatus("Loading…")
        }
        statusSummaryLabel.stringValue = ""
    }

    public func displayHomePage(_ model: BrowserHomePageModel) {
        loadViewIfNeeded()
        homePageController.display(model)
        homePageController.view.isHidden = false
        fileContentController.view.isHidden = true
        breadcrumbBar.display(.computer)
        showStatus("Home view")
        statusSummaryLabel.stringValue = ""
        previewView.display([])
        setViewModeControlVisible(false)
    }

    public func selectSidebarLocation(_ location: BrowserLocation) {
        sidebarController.select(location)
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
        homePageController.view.isHidden = true
        fileContentController.view.isHidden = false
        fileContentController.display(rows, selecting: selectedURLs)
        setViewModeControlVisible(true)
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

    private func setViewModeControlVisible(_ isVisible: Bool) {
        viewModeControl.isHidden = !isVisible
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

    public func setSidebarVisible(_ isVisible: Bool) {
        guard isSidebarVisible != isVisible else { return }
        isSidebarVisible = isVisible
        loadViewIfNeeded()
        guard let splitView else { return }
        if isVisible {
            let sidebarView = self.sidebarView ?? makeSidebar()
            self.sidebarView = sidebarView
            guard sidebarView.superview !== splitView else { return }
            splitView.insertArrangedSubview(sidebarView, at: 0)
            setSidebarWidth(requestedSidebarWidth)
        } else {
            guard let sidebarView else { return }
            guard sidebarView.superview === splitView else { return }
            canReportSidebarWidth = false
            splitView.removeArrangedSubview(sidebarView)
            sidebarView.removeFromSuperview()
            splitView.adjustSubviews()
        }
    }

    public func setPaneActive(_ isActive: Bool, showsIndicator: Bool) {
        loadViewIfNeeded()
        isPaneActive = isActive
        view.layer?.borderWidth = 0
        activePaneIndicator.isHidden = !showsIndicator || !isActive
        view.setAccessibilityLabel(isActive ? "Active file pane" : "File pane")
    }

    /// Updates the split-view control without coupling the browser chrome to
    /// the window's pane-session ownership.
    public func setDualPaneActive(_ isActive: Bool) {
        let title = isActive ? "Close Split View" : "Show Split View"
        dualPaneButton.toolTip = "\(title) (Command-\\)"
        dualPaneButton.setAccessibilityLabel(title)
    }

    public func focusFileContent() {
        fileContentController.focusContent()
    }

    public func selectFileURLs(_ urls: Set<URL>) {
        fileContentController.setSelection(urls)
    }

    public func fileContentScrollPosition() -> BrowserScrollPosition? {
        fileContentController.scrollPosition()
    }

    public func restoreFileContentScrollPosition(_ position: BrowserScrollPosition) {
        fileContentController.restoreScrollPosition(position)
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
        if isSidebarVisible {
            let sidebar = makeSidebar()
            sidebarView = sidebar
            splitView.addArrangedSubview(sidebar)
        }
        splitView.addArrangedSubview(makeContentArea())
        splitView.delegate = self
        self.splitView = splitView
        if isSidebarVisible {
            setSidebarWidth(requestedSidebarWidth)
        }
        return splitView
    }

    private func makeSidebar() -> NSView {
        let container = NSVisualEffectView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .sidebar
        container.blendingMode = .withinWindow
        container.state = .active

        sidebarController.viewState = viewState
        sidebarController.onAction = { [weak self] action in
            _ = self?.emit(action)
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

        breadcrumbBar.onNavigate = { [weak self] location in
            _ = self?.emit(.openLocation(location))
        }
        breadcrumbBar.onSubmitPath = { [weak self] path in
            _ = self?.emit(.submitPath(path))
        }
        configureSearchField()
        configureViewModeControl()
        configureDualPaneButton()
        configureStatusLabels()

        if fileContentController.parent !== self {
            addChild(fileContentController)
        }
        if homePageController.parent !== self {
            addChild(homePageController)
        }
        let contentView = fileContentController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        let homeView = homePageController.view
        homeView.translatesAutoresizingMaskIntoConstraints = false
        homeView.isHidden = true

        let contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(contentView)
        contentHost.addSubview(homeView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            homeView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            homeView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            homeView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])

        let browserSplitView = NSSplitView()
        browserSplitView.isVertical = true
        browserSplitView.dividerStyle = .thin
        browserSplitView.translatesAutoresizingMaskIntoConstraints = false
        browserSplitView.addArrangedSubview(contentHost)
        if isPreviewVisible {
            browserSplitView.addArrangedSubview(previewView)
        }
        browserSplitView.delegate = self
        let contentMinimum = contentHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 300)
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

        let topRow = NSStackView(views: [
            navigation,
            breadcrumbBar,
            searchField,
            viewModeControl,
            dualPaneButton,
        ])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 8
        topRow.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)

        let breadcrumbPreferredWidth = breadcrumbBar.widthAnchor.constraint(
            greaterThanOrEqualToConstant: ToolbarLayout.preferredBreadcrumbWidth
        )
        breadcrumbPreferredWidth.priority = NSLayoutConstraint.Priority(
            rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue + 1
        )

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
            breadcrumbBar.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ToolbarLayout.minimumBreadcrumbWidth
            ),
            breadcrumbPreferredWidth,
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
        searchField.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue - 1),
            for: .horizontal
        )
        let preferredWidth = searchField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: ToolbarLayout.preferredSearchWidth
        )
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ToolbarLayout.minimumSearchWidth
            ),
            preferredWidth,
        ])
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
        viewModeControl.identifier = NSUserInterfaceItemIdentifier("browser.viewMode")
        viewModeControl.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureDualPaneButton() {
        dualPaneButton.image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: "Show Split View"
        )
        dualPaneButton.bezelStyle = .inline
        dualPaneButton.isBordered = false
        dualPaneButton.target = self
        dualPaneButton.action = #selector(toggleDualPane(_:))
        dualPaneButton.identifier = NSUserInterfaceItemIdentifier("browser.dualPane")
        dualPaneButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dualPaneButton.widthAnchor.constraint(equalToConstant: 24),
            dualPaneButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        setDualPaneActive(false)
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
        let button = BrowserToolbarButton()
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
        _ = emit(.navigation(commands[sender.tag]))
    }

    @objc private func changeViewMode(_ sender: NSSegmentedControl) {
        _ = emit(.setViewMode(sender.selectedSegment == 1 ? .icons : .details))
    }

    @objc private func toggleDualPane(_ sender: NSButton) {
        _ = emit(.toggleDualPane)
    }

    @objc private func submitSearch(_ sender: Any?) {
        notifySearchChange()
    }

    private func notifySearchChange() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            _ = emit(.clearSearch)
        } else {
            _ = emit(.search(query))
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
              let splitView, notification.object as? NSSplitView === splitView,
              isSidebarVisible, splitView.subviews.count > 1 else { return }
        let width = splitView.subviews[0].frame.width
        guard width >= SidebarLayout.minimumWidth,
              width <= SidebarLayout.maximumWidth else { return }
        requestedSidebarWidth = width
        _ = emit(.sidebarWidthChange(width))
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

    private func applyViewState() {
        sidebarController.viewState = viewState
        homePageController.viewState = viewState
        fileContentController.viewState = viewState
    }

    @discardableResult
    private func emit(_ action: BrowserAction) -> Bool {
        if let onAction {
            return onAction(action)
        }
        switch action {
        case .dropFiles, .dropPromisedFiles:
            return false
        default:
            return true
        }
    }
}

private enum SidebarLayout {
    static let defaultWidth: CGFloat = 176
    static let minimumWidth: CGFloat = 148
    static let maximumWidth: CGFloat = 300
    static let minimumContentWidth: CGFloat = 480
}

private enum ToolbarLayout {
    static let preferredBreadcrumbWidth: CGFloat = 260
    static let minimumBreadcrumbWidth: CGFloat = 92
    static let preferredSearchWidth: CGFloat = 150
    static let minimumSearchWidth: CGFloat = 32
}
