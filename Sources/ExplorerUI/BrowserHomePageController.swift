import AppKit

/// The My Computer overview: favorites, volumes with free space, and network locations.
@MainActor
final class BrowserHomePageController: NSViewController {
    var onOpenLocation: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = BrowserHomeDocumentView()
    private let stack = FlippedStackView()
    private var model = BrowserHomePageModel.empty
    private weak var selectedHomeTile: BrowserHomeItemView?

    override func loadView() {
        view = BrowserHomeRootView()
        view.identifier = NSUserInterfaceItemIdentifier("home.page")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("My Computer")

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 28, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.onBackgroundMouseDown = { [weak self] in self?.clearHomeSelection() }

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    func display(_ model: BrowserHomePageModel) {
        loadViewIfNeeded()
        self.model = model
        rebuild()
    }

    private func rebuild() {
        clearHomeSelection()
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let title = NSTextField(labelWithString: BrowserComputerLocation.title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.setAccessibilityLabel("My Computer")
        title.identifier = NSUserInterfaceItemIdentifier("home.title")
        title.setContentHuggingPriority(.required, for: .vertical)
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(title)
        pinToContentWidth(title)

        if !model.favorites.isEmpty {
            addSection(
                title: "Favorites",
                count: model.favorites.count,
                identifier: "home.section.favorites",
                tiles: model.favorites.map(makeFavoriteTile),
                columns: 3,
                rowHeight: 52
            )
        }
        if !model.volumes.isEmpty {
            addSection(
                title: "Devices and Drives",
                count: model.volumes.count,
                identifier: "home.section.volumes",
                tiles: model.volumes.map(makeVolumeTile),
                columns: 2,
                rowHeight: 64
            )
        }
        if !model.network.isEmpty {
            addSection(
                title: "Network Locations",
                count: model.network.count,
                identifier: "home.section.network",
                tiles: model.network.map(makeFavoriteTile),
                columns: 3,
                rowHeight: 52
            )
        }
    }

    private func addSection(
        title: String,
        count: Int,
        identifier: String,
        tiles: [NSView],
        columns: Int,
        rowHeight: CGFloat
    ) {
        let header = NSTextField(labelWithString: "\(title) (\(count))")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .labelColor

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let grid = BrowserHomeTileGrid()
        grid.columns = columns
        grid.rowHeight = rowHeight
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.setContentCompressionResistancePriority(.required, for: .vertical)
        grid.setTiles(tiles)
        grid.onBackgroundMouseDown = { [weak self] in self?.clearHomeSelection() }
        let section = FlippedStackView(views: [header, divider, grid])
        section.onBackgroundMouseDown = { [weak self] in self?.clearHomeSelection() }
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.identifier = NSUserInterfaceItemIdentifier(identifier)
        section.setAccessibilityElement(true)
        section.setAccessibilityRole(.list)
        section.setAccessibilityLabel(title)
        section.setHuggingPriority(.required, for: .vertical)
        header.setContentHuggingPriority(.defaultHigh, for: .vertical)
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalTo: section.widthAnchor),
            grid.widthAnchor.constraint(equalTo: section.widthAnchor),
        ])
        stack.addArrangedSubview(section)
        pinToContentWidth(section)
    }

    private func pinToContentWidth(_ view: NSView) {
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func makeFavoriteTile(_ item: BrowserHomePageItem) -> NSView {
        let icon = NSImageView(image: icon(for: item.url, fallback: "folder"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        let name = NSTextField(labelWithString: item.title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.isEditable = false
        name.isSelectable = false

        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.isEditable = false
        subtitle.isSelectable = false

        let labels = NSStackView(views: [name, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        return makeTile(
            icon: icon,
            content: labels,
            title: item.title,
            subtitle: item.subtitle,
            url: item.url
        )
    }

    private func makeVolumeTile(_ volume: BrowserHomePageVolume) -> NSView {
        let icon = NSImageView(image: icon(for: volume.url, fallback: "externaldrive.fill"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
        ])

        let name = NSTextField(labelWithString: volume.title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.isEditable = false
        name.isSelectable = false
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = BrowserCapacityBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        if let fraction = volume.usedFraction {
            bar.fraction = CGFloat(fraction)
            bar.isHidden = false
        } else {
            bar.isHidden = true
        }
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 6),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        let titleRow = NSStackView(views: [name, bar])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 10
        titleRow.distribution = .fill

        let caption = NSTextField(labelWithString: volume.caption ?? volume.url.path)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.isEditable = false
        caption.isSelectable = false
        caption.identifier = NSUserInterfaceItemIdentifier("home.volume.caption")

        let labels = NSStackView(views: [titleRow, caption])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        titleRow.setHuggingPriority(.defaultLow, for: .horizontal)
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        return makeTile(
            icon: icon,
            content: labels,
            title: volume.title,
            subtitle: volume.caption ?? volume.url.path,
            url: volume.url
        )
    }

    private func makeTile(
        icon: NSImageView,
        content: NSView,
        title: String,
        subtitle: String,
        url: URL
    ) -> BrowserHomeItemView {
        let tile = BrowserHomeItemView()
        tile.identifier = NSUserInterfaceItemIdentifier("home.item")
        tile.setAccessibilityLabel("\(title). \(subtitle)")
        tile.onOpen = { [weak self] in self?.onOpenLocation?(url) }
        tile.onSelect = { [weak self, weak tile] in
            guard let tile else { return }
            self?.selectHomeTile(tile)
        }

        let row = NSStackView(views: [icon, content])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tile.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            row.topAnchor.constraint(equalTo: tile.topAnchor),
            row.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
        ])
        return tile
    }

    private func icon(for url: URL, fallback: String) -> NSImage {
        if url.isFileURL {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 32, height: 32)
            return image
        }
        let image = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    private func selectHomeTile(_ tile: BrowserHomeItemView) {
        if selectedHomeTile !== tile {
            selectedHomeTile?.isSelected = false
            selectedHomeTile = tile
            tile.isSelected = true
        }
        view.window?.makeFirstResponder(tile)
    }

    private func clearHomeSelection() {
        selectedHomeTile?.isSelected = false
        selectedHomeTile = nil
    }
}

private final class BrowserHomeRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if let tile = homeTile(at: point) {
            return tile
        }
        return super.hitTest(point)
    }

    private func homeTile(at point: NSPoint) -> BrowserHomeItemView? {
        func search(_ view: NSView) -> BrowserHomeItemView? {
            guard !view.isHidden else { return nil }
            if let tile = view as? BrowserHomeItemView {
                let rect = tile.convert(tile.bounds, to: self)
                return rect.contains(point) ? tile : nil
            }
            for child in view.subviews.reversed() {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(self)
    }
}

private final class BrowserHomeDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedStackView: NSStackView {
    var onBackgroundMouseDown: (() -> Void)?
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?()
        super.mouseDown(with: event)
    }
}

private final class BrowserHomeTileGrid: NSView {
    var columns = 3
    var rowHeight: CGFloat = 52
    var spacing: CGFloat = 12
    var onBackgroundMouseDown: (() -> Void)?
    private var tiles: [NSView] = []

    override var isFlipped: Bool { true }
    private var heightConstraint: NSLayoutConstraint?

    override var intrinsicContentSize: NSSize {
        let rows = tileRows
        let height = rows == 0 ? 1 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * spacing
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    private var tileRows: Int {
        guard columns > 0, !tiles.isEmpty else { return 0 }
        return (tiles.count + columns - 1) / columns
    }

    func setTiles(_ views: [NSView]) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = views
        views.forEach { tile in
            tile.translatesAutoresizingMaskIntoConstraints = true
            tile.autoresizingMask = []
            addSubview(tile)
        }
        invalidateIntrinsicContentSize()
        let height = intrinsicContentSize.height
        if let heightConstraint {
            heightConstraint.constant = height
        } else {
            let constraint = heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true
            heightConstraint = constraint
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, columns > 0 else { return }
        let columnWidth = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            tile.frame = NSRect(
                x: CGFloat(column) * (columnWidth + spacing),
                y: CGFloat(row) * (rowHeight + spacing),
                width: columnWidth,
                height: rowHeight
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for tile in tiles.reversed() where tile.frame.contains(point) {
            return tile
        }
        return bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?()
    }
}

final class BrowserHomeItemView: NSView {
    var onOpen: (() -> Void)?
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
    }

    override var isFlipped: Bool { true }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        guard event.clickCount >= 2 else { return }
        let handler = onOpen
        DispatchQueue.main.async {
            handler?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" {
            performOpen()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        performOpen()
        return true
    }

    func performOpen() {
        onOpen?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let fill: NSColor?
        if isSelected {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.22)
        } else if isHovered {
            fill = NSColor.controlAccentColor.withAlphaComponent(0.09)
        } else {
            fill = nil
        }
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

private final class BrowserCapacityBar: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds
        NSColor.separatorColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let width = max(0, min(1, fraction)) * track.width
        guard width > 0.5 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: track.minX, y: track.minY, width: width, height: track.height),
            xRadius: 3,
            yRadius: 3
        ).fill()
    }
}
