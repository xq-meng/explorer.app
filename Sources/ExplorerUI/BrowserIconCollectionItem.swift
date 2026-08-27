import AppKit

/// A reusable icon-grid cell. It requests the system icon only when AppKit asks
/// for a visible/reused item; directory snapshots never eagerly load icons.
final class BrowserIconCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ExplorerBrowserIconItem")
    private(set) var representedURL: URL?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        view = NSView()
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
    }

    func display(_ row: BrowserFileRow, thumbnail: NSImage? = nil) {
        representedURL = row.url
        nameLabel.stringValue = row.name
        nameLabel.setAccessibilityLabel("\(row.kind): \(row.name)")
        iconView.image = thumbnail ?? NSWorkspace.shared.icon(forFile: row.url.path)
        iconView.setAccessibilityLabel(row.kind)
        view.setAccessibilityLabel("\(row.kind): \(row.name)")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconView.image = nil
        nameLabel.stringValue = ""
        representedURL = nil
    }
}
