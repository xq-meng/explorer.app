import AppKit

/// Clickable path navigation that can switch to an editable address field.
/// It deals only in file URLs; validation remains in the application layer.
@MainActor
final class BrowserBreadcrumbBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((URL) -> Void)?
    var onSubmitPath: ((String) -> Void)?

    private let componentStack = NSStackView()
    private let scrollView = NSScrollView()
    private let pathField = NSTextField()
    private let editButton = NSButton()
    private var displayedURL = URL(fileURLWithPath: "/")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        componentStack.orientation = .horizontal
        componentStack.alignment = .centerY
        componentStack.spacing = 2
        componentStack.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 4)

        scrollView.documentView = componentStack
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        pathField.placeholderString = "Enter a folder path"
        pathField.isHidden = true
        pathField.isBordered = false
        pathField.focusRingType = .none
        pathField.font = .systemFont(ofSize: 13)
        pathField.delegate = self
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.setAccessibilityLabel("Folder path")
        pathField.setAccessibilityHelp("Type a folder path, then press Return to navigate.")

        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit path")
        editButton.bezelStyle = .inline
        editButton.isBordered = false
        editButton.target = self
        editButton.action = #selector(beginEditingPath(_:))
        editButton.toolTip = "Edit path (Command-L)"
        editButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(pathField)
        addSubview(editButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scrollView.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -2),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            pathField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            pathField.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -5),
            pathField.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 20),
            editButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginEditingPath(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)
        display(URL(fileURLWithPath: "/"))
    }

    required init?(coder: NSCoder) { nil }

    func display(_ url: URL) {
        displayedURL = url.standardizedFileURL
        pathField.stringValue = displayedURL.path
        rebuildComponents()
    }

    func focusAddressField() {
        beginEditingPath(nil)
    }

    private func rebuildComponents() {
        componentStack.arrangedSubviews.forEach {
            componentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let components = displayedURL.pathComponents
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            if index > 0 {
                cursor.appendPathComponent(component, isDirectory: true)
                componentStack.addArrangedSubview(makeSeparator())
            }
            let title = component == "/" ? "Computer" : component
            componentStack.addArrangedSubview(makeComponentButton(title: title, url: cursor))
        }
        componentStack.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: max(0, componentStack.fittingSize.width - scrollView.contentSize.width), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeComponentButton(title: String, url: URL) -> NSButton {
        let button = BreadcrumbButton(title: title, url: url, target: self, action: #selector(selectComponent(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.lineBreakMode = .byTruncatingMiddle
        button.toolTip = url.path
        button.setAccessibilityLabel("Go to \(title)")
        return button
    }

    private func makeSeparator() -> NSImageView {
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = .tertiaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 8),
            view.heightAnchor.constraint(equalToConstant: 13),
        ])
        return view
    }

    @objc private func selectComponent(_ sender: NSButton) {
        guard let url = (sender as? BreadcrumbButton)?.url else { return }
        onNavigate?(url)
    }

    @objc private func beginEditingPath(_ sender: Any?) {
        pathField.stringValue = displayedURL.path
        pathField.isHidden = false
        scrollView.isHidden = true
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private func endEditingPath() {
        pathField.isHidden = true
        scrollView.isHidden = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            endEditingPath()
            if !path.isEmpty { onSubmitPath?(path) }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditingPath()
            return true
        }
        return false
    }
}

private final class BreadcrumbButton: NSButton {
    let url: URL

    init(title: String, url: URL, target: AnyObject?, action: Selector?) {
        self.url = url.standardizedFileURL
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { nil }
}
