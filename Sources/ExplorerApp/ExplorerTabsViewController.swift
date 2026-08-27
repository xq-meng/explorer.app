import AppKit

@MainActor
final class ExplorerTabsViewController: NSViewController, NSTabViewDelegate {
    var onSelectionChange: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onTabsReordered: (() -> Void)?

    private let tabView = NSTabView()
    private let tabStrip = ExplorerTabStripView()

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
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
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

        view.addSubview(tabStrip)
        view.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: view.topAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 38),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
private final class ExplorerTabStripView: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?

    private let tabStack = NSStackView()
    private let addButton = NSButton()
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        registerForDraggedTypes([.explorerTabIndex])

        tabStack.orientation = .horizontal
        tabStack.alignment = .bottom
        tabStack.spacing = 3
        tabStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 0, right: 8)
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addTab(_:))
        addButton.toolTip = "New Tab (Command-T)"
        addButton.translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabStack)
        addSubview(addButton)
        addSubview(separator)
        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStack.topAnchor.constraint(equalTo: topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            addButton.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor, constant: 2),
            addButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 26),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(titles: [String], selectedIndex: Int) {
        tabStack.arrangedSubviews.forEach {
            tabStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, title) in titles.enumerated() {
            let item = ExplorerTabItemView(title: title, isSelected: index == selectedIndex, dragIndex: index)
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
            tabStack.addArrangedSubview(item)
        }
    }

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
        let point = convert(info.draggingLocation, from: nil)
        var destination = tabStack.arrangedSubviews.firstIndex { item in
            point.x < convert(item.bounds, from: item).midX
        } ?? tabStack.arrangedSubviews.count
        if source < destination { destination -= 1 }
        destination = min(max(0, destination), tabStack.arrangedSubviews.count - 1)
        return (source, destination)
    }

    @objc private func addTab(_ sender: Any?) { onNewTab?() }
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
            heightAnchor.constraint(equalToConstant: 30),
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
