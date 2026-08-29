import AppKit

enum BrowserItemVisualState: Equatable {
    case normal
    case hovered
    case selected
    case dropTarget
}

enum BrowserItemPresentation {
    static let dimmedAlpha: CGFloat = 0.52
}

/// Adds pointer feedback without replacing AppKit's active/inactive selection
/// rendering or its drag-destination treatment.
final class BrowserFileTableRowView: NSTableRowView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ExplorerBrowserFileRow")

    private var pointerTrackingArea: NSTrackingArea?
    private(set) var isHovered = false

    var visualState: BrowserItemVisualState {
        if isTargetForDropOperation { return .dropTarget }
        if isSelected { return .selected }
        if isHovered { return .hovered }
        return .normal
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard visualState == .hovered else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    func resetHover() {
        setHovered(false)
    }
}

/// Draws the icon-grid feedback behind the item's image and label. The view
/// listens for key-window changes so selection becomes subdued when inactive.
final class BrowserIconItemView: NSView {
    private var pointerTrackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?
    private(set) var isHovered = false

    var isItemSelected = false {
        didSet { if oldValue != isItemSelected { needsDisplay = true } }
    }

    var isDropTarget = false {
        didSet { if oldValue != isDropTarget { needsDisplay = true } }
    }

    var visualState: BrowserItemVisualState {
        if isDropTarget { return .dropTarget }
        if isItemSelected { return .selected }
        if isHovered { return .hovered }
        return .normal
    }

    override func viewDidMoveToWindow() {
        stopObservingWindow()
        super.viewDidMoveToWindow()
        observedWindow = window
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowActivityDidChange(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowActivityDidChange(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let highlightBounds = bounds.insetBy(dx: 2, dy: 2)
        let highlightPath = NSBezierPath(
            roundedRect: highlightBounds,
            xRadius: 7,
            yRadius: 7
        )

        switch visualState {
        case .normal:
            return
        case .hovered:
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
            highlightPath.fill()
        case .selected:
            let color = window?.isKeyWindow != true
                ? NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.72)
                : NSColor.controlAccentColor.withAlphaComponent(0.22)
            color.setFill()
            highlightPath.fill()
        case .dropTarget:
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            highlightPath.fill()
            NSColor.controlAccentColor.setStroke()
            highlightPath.lineWidth = 2
            highlightPath.stroke()
        }
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }

    func resetPresentation() {
        isItemSelected = false
        isDropTarget = false
        setHovered(false)
    }

    @objc private func windowActivityDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    private func stopObservingWindow() {
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: observedWindow
        )
        self.observedWindow = nil
    }
}
