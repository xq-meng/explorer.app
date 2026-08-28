import AppKit

public struct BrowserOperationActivity: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var fractionCompleted: Double
    public var queuedCount: Int

    public init(title: String, detail: String, fractionCompleted: Double, queuedCount: Int = 0) {
        self.title = title
        self.detail = detail
        self.fractionCompleted = min(1, max(0, fractionCompleted))
        self.queuedCount = queuedCount
    }
}

@MainActor
public final class BrowserOperationActivityView: NSView {
    public var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let separator = NSBox()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    public func display(_ activity: BrowserOperationActivity?) {
        guard let activity else {
            isHidden = true
            progressIndicator.stopAnimation(nil)
            return
        }
        isHidden = false
        titleLabel.stringValue = activity.title
        detailLabel.stringValue = activity.detail
        detailLabel.toolTip = activity.detail
        progressIndicator.doubleValue = activity.fractionCompleted * 100
        progressIndicator.startAnimation(nil)
        cancelButton.isEnabled = true
        setAccessibilityLabel(activity.title)
        setAccessibilityValue(activity.detail)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("File operation progress")

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.setAccessibilityLabel("Operation progress")

        cancelButton.bezelStyle = .flexiblePush
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelCurrentFileOperation(_:))
        cancelButton.setAccessibilityLabel("Cancel file operation")

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let content = NSStackView(views: [labels, progressIndicator, cancelButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(content)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: separator.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            progressIndicator.heightAnchor.constraint(equalToConstant: 12),
            labels.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        content.setHuggingPriority(.defaultLow, for: .horizontal)
        progressIndicator.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func cancelCurrentFileOperation(_ sender: Any?) {
        cancelButton.isEnabled = false
        onCancel?()
    }
}
