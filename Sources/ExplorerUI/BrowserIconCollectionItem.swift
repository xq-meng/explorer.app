import AppKit

/// A reusable icon-grid cell. It requests the system icon only when AppKit asks
/// for a visible/reused item; directory snapshots never eagerly load icons.
final class BrowserIconCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ExplorerBrowserIconItem")
    private(set) var representedURL: URL?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")

    override var isSelected: Bool {
        didSet { updatePresentation() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updatePresentation() }
    }

    override func loadView() {
        view = BrowserIconItemView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)
        view.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -4),
        ])
        updatePresentation()
    }

    func display(_ row: BrowserFileRow, thumbnail: NSImage? = nil, isCut: Bool = false) {
        representedURL = row.url
        nameLabel.stringValue = row.name
        let isDimmed = row.isHidden || isCut
        let alpha = isDimmed ? BrowserItemPresentation.dimmedAlpha : 1
        nameLabel.alphaValue = alpha
        iconView.alphaValue = alpha
        let stateDescription = [
            row.isHidden ? "hidden" : nil,
            isCut ? "cut" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        let accessibilityLabel = stateDescription.isEmpty
            ? "\(row.kind): \(row.name)"
            : "\(row.kind): \(row.name), \(stateDescription)"
        nameLabel.setAccessibilityLabel(accessibilityLabel)
        iconView.image = thumbnail ?? NSWorkspace.shared.icon(forFile: row.url.path)
        iconView.setAccessibilityLabel(row.kind)
        view.setAccessibilityLabel(accessibilityLabel)
        updatePresentation()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        (view as? BrowserIconItemView)?.resetPresentation()
        iconView.image = nil
        iconView.alphaValue = 1
        nameLabel.stringValue = ""
        nameLabel.alphaValue = 1
        representedURL = nil
    }

    private func updatePresentation() {
        guard isViewLoaded, let itemView = view as? BrowserIconItemView else { return }
        itemView.isItemSelected = isSelected || highlightState == .forSelection
        itemView.isDropTarget = highlightState == .asDropTarget
    }
}
