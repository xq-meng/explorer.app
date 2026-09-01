import AppKit

/// Borderless toolbar button with discoverable pointer feedback.
@MainActor
class BrowserToolbarButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var isHovered = false

    var showsHoverHighlight: Bool { isHovered && isEnabled }

    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled { needsDisplay = true }
        }
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
        if showsHoverHighlight {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
        super.draw(dirtyRect)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
    }
}
