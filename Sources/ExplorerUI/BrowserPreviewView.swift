import AppKit
@preconcurrency import QuickLookUI

/// Embedded Quick Look preview with Explorer-style file metadata.
@MainActor
final class BrowserPreviewView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Select an item")
    private let metadataLabel = NSTextField(wrappingLabelWithString: "Select a file or folder to see its details.")
    private let iconView = NSImageView()
    private let previewHost = NSView()
    private var quickLookView: QLPreviewView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 2
        metadataLabel.font = .preferredFont(forTextStyle: .caption1)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.maximumNumberOfLines = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [iconView, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [header, metadataLabel, separator, previewHost])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            metadataLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        setAccessibilityLabel("Preview pane")
    }

    required init?(coder: NSCoder) { nil }

    func display(_ rows: [BrowserFileRow]) {
        switch rows.count {
        case 0:
            titleLabel.stringValue = "Select an item"
            metadataLabel.stringValue = "Select a file or folder to see its details."
            iconView.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
            setPreviewURL(nil)
        case 1:
            let row = rows[0]
            titleLabel.stringValue = row.name
            metadataLabel.stringValue = [
                "Kind:  \(row.kind)",
                "Size:  \(row.size)",
                "Modified:  \(row.modifiedDate)",
                "Path:  \(row.url.path)",
            ].joined(separator: "\n")
            iconView.image = NSWorkspace.shared.icon(forFile: row.url.path)
            setPreviewURL(row.url)
        default:
            titleLabel.stringValue = "\(rows.count) items selected"
            let totalBytes = rows.compactMap(\.sizeInBytes).reduce(0, +)
            let folders = rows.filter(\.isNavigable).count
            let files = rows.count - folders
            var details = "\(files) file\(files == 1 ? "" : "s"), \(folders) folder\(folders == 1 ? "" : "s")"
            if totalBytes > 0 {
                details += "\nTotal file size: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
            }
            metadataLabel.stringValue = details
            iconView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)
            setPreviewURL(nil)
        }
    }

    private func setPreviewURL(_ url: URL?) {
        guard let url else {
            quickLookView?.previewItem = nil
            quickLookView?.isHidden = true
            return
        }
        let view: QLPreviewView
        if let quickLookView {
            view = quickLookView
        } else {
            guard let created = QLPreviewView(frame: .zero, style: .normal) else { return }
            created.translatesAutoresizingMaskIntoConstraints = false
            created.autostarts = true
            previewHost.addSubview(created)
            NSLayoutConstraint.activate([
                created.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
                created.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
                created.topAnchor.constraint(equalTo: previewHost.topAnchor),
                created.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
            ])
            quickLookView = created
            view = created
        }
        view.isHidden = false
        view.previewItem = url as NSURL
    }
}
