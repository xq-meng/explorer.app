import AppKit
import ExplorerUI

@MainActor
final class ExplorerTabsViewController: NSViewController, NSTabViewDelegate {
    var onSelectionChange: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onTabsReordered: (() -> Void)?
    var onCancelOperation: (() -> Void)?

    private let tabView = NSTabView()
    private let tabStrip = ExplorerTabStripView()
    private let activityView = BrowserOperationActivityView()
    private var activityHeightConstraint: NSLayoutConstraint?
    private var titlebarAccessoryController: ExplorerTabTitlebarAccessoryViewController?

    var tabViewItems: [NSTabViewItem] { tabView.tabViewItems }

    var selectedTabViewItemIndex: Int {
        get {
            guard let selected = tabView.selectedTabViewItem else { return -1 }
            return tabView.tabViewItems.firstIndex(of: selected) ?? -1
        }
        set {
            guard tabView.tabViewItems.indices.contains(newValue) else { return }
            tabView.selectTabViewItem(at: newValue)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        tabView.tabViewType = .noTabsNoBorder
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelect = { [weak self] index in self?.selectedTabViewItemIndex = index }
        tabStrip.onNewTab = { [weak self] in self?.onNewTab?() }
        tabStrip.onClose = { [weak self] index in
            guard let self else { return }
            selectedTabViewItemIndex = index
            onCloseTab?()
        }
        tabStrip.onMove = { [weak self] source, destination in
            self?.moveTab(from: source, to: destination)
        }

        view.addSubview(tabView)
        view.addSubview(activityView)
        activityView.translatesAutoresizingMaskIntoConstraints = false
        activityView.onCancel = { [weak self] in self?.onCancelOperation?() }
        let activityHeight = activityView.heightAnchor.constraint(equalToConstant: 0)
        activityHeightConstraint = activityHeight
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: view.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: activityView.topAnchor),
            activityView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            activityView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            activityView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityHeight,
        ])
    }

    func setOperationActivity(_ activity: BrowserOperationActivity?) {
        loadViewIfNeeded()
        activityView.display(activity)
        activityHeightConstraint?.constant = activity == nil ? 0 : 56
    }

    func makeTitlebarAccessoryViewController() -> NSTitlebarAccessoryViewController {
        loadViewIfNeeded()
        if let titlebarAccessoryController { return titlebarAccessoryController }
        let controller = ExplorerTabTitlebarAccessoryViewController(tabStrip: tabStrip)
        titlebarAccessoryController = controller
        return controller
    }

    func setTitlebarAccessoryWidth(_ width: CGFloat) {
        titlebarAccessoryController?.setPreferredWidth(width)
    }

    func addTabViewItem(_ item: NSTabViewItem) {
        tabView.addTabViewItem(item)
        refreshTabs()
    }

    func removeTabViewItem(_ item: NSTabViewItem) {
        tabView.removeTabViewItem(item)
        refreshTabs()
    }

    func refreshTabs() {
        tabStrip.update(
            titles: tabView.tabViewItems.map { $0.label.isEmpty ? "Folder" : $0.label },
            selectedIndex: selectedTabViewItemIndex
        )
    }

    private func moveTab(from source: Int, to destination: Int) {
        guard tabView.tabViewItems.indices.contains(source),
              tabView.tabViewItems.indices.contains(destination),
              source != destination else { return }
        let item = tabView.tabViewItems[source]
        let wasSelected = item === tabView.selectedTabViewItem
        tabView.removeTabViewItem(item)
        tabView.insertTabViewItem(item, at: destination)
        if wasSelected { tabView.selectTabViewItem(item) }
        refreshTabs()
        onTabsReordered?()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        refreshTabs()
        onSelectionChange?()
    }
}

@MainActor
private final class ExplorerTabTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private static let preferredHeight: CGFloat = 30
    private let tabStrip: ExplorerTabStripView

    init(tabStrip: ExplorerTabStripView) {
        self.tabStrip = tabStrip
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .leading
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        tabStrip.frame = NSRect(x: 0, y: 0, width: 800, height: Self.preferredHeight)
        tabStrip.autoresizingMask = [.width, .height]
        view = tabStrip
    }

    func setPreferredWidth(_ width: CGFloat) {
        loadViewIfNeeded()
        view.setFrameSize(NSSize(width: max(0, width), height: Self.preferredHeight))
    }
}

@MainActor
private final class ExplorerTabStripView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?

    private let scrollView = ExplorerTabScrollView()
    private let tabStack = ExplorerTabStackView()
    private let addButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.explorerTabIndex])

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 3
        tabStack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 8)
        tabStack.frame = NSRect(x: 0, y: 0, width: 38, height: 30)
        tabStack.translatesAutoresizingMaskIntoConstraints = true

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = tabStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addTab(_:))
        addButton.toolTip = "New Tab (Command-T)"
        addButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        tabStack.addArrangedSubview(addButton)

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(titles: [String], selectedIndex: Int) {
        tabStack.arrangedSubviews.filter { $0 !== addButton }.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        var selectedItem: ExplorerTabItemView?
        for (index, title) in titles.enumerated() {
            let item = ExplorerTabItemView(title: title, isSelected: index == selectedIndex, dragIndex: index)
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            tabStack.insertArrangedSubview(item, at: index)
            if index == selectedIndex { selectedItem = item }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let selectedItem { tabStack.scrollToVisible(selectedItem.frame) }
    }

    override func layout() {
        super.layout()
        let viewportSize = scrollView.contentSize
        let fittingSize = tabStack.fittingSize
        tabStack.frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewportSize.width, fittingSize.width),
            height: viewportSize.height
        )
        tabStack.layoutSubtreeIfNeeded()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        proposedMove(for: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        proposedMove(for: sender) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (source, destination) = proposedMove(for: sender) else { return false }
        if source != destination { onMove?(source, destination) }
        return true
    }

    private func proposedMove(for info: NSDraggingInfo) -> (Int, Int)? {
        guard let sourceView = info.draggingSource as? ExplorerTabItemView,
              tabStack.arrangedSubviews.contains(where: { $0 === sourceView }) else { return nil }
        let source = sourceView.dragIndex
        let point = tabStack.convert(info.draggingLocation, from: nil)
        var destination = tabStack.arrangedSubviews.firstIndex { item in
            item !== addButton && point.x < item.frame.midX
        } ?? max(0, tabStack.arrangedSubviews.count - 1)
        if source < destination { destination -= 1 }
        destination = min(max(0, destination), max(0, tabStack.arrangedSubviews.count - 2))
        return (source, destination)
    }

    @objc private func addTab(_ sender: Any?) { onNewTab?() }
}

@MainActor
private final class ExplorerTabScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class ExplorerTabStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
private final class ExplorerTabItemView: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    let dragIndex: Int

    init(title: String, isSelected: Bool, dragIndex: Int) {
        self.dragIndex = dragIndex
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor

        let selectButton = NSButton(title: title, target: self, action: #selector(selectTab(_:)))
        selectButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        selectButton.imagePosition = .imageLeading
        selectButton.imageHugsTitle = true
        selectButton.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        selectButton.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        selectButton.alignment = .left
        selectButton.lineBreakMode = .byTruncatingMiddle
        selectButton.bezelStyle = .inline
        selectButton.isBordered = false
        selectButton.toolTip = title

        let closeButton = NSButton()
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.toolTip = "Close Tab"

        let stack = NSStackView(views: [selectButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            widthAnchor.constraint(lessThanOrEqualToConstant: 210),
            heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        let dragRecognizer = NSPanGestureRecognizer(target: self, action: #selector(dragTab(_:)))
        addGestureRecognizer(dragRecognizer)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectTab(_ sender: Any?) { onSelect?() }
    @objc private func closeTab(_ sender: Any?) { onClose?() }

    @objc private func dragTab(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began, let event = NSApp.currentEvent else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(dragIndex), forType: .explorerTabIndex)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: draggingImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func draggingImage() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

private extension NSPasteboard.PasteboardType {
    static let explorerTabIndex = NSPasteboard.PasteboardType("app.explorer.tab-index")
}
