import AppKit

/// Clickable path navigation that can switch to an editable address field.
/// It deals only in file URLs; validation remains in the application layer.
@MainActor
final class BrowserBreadcrumbBar: NSView, NSTextFieldDelegate {
    var onNavigate: ((BrowserLocation) -> Void)?
    var onSubmitPath: ((String) -> Void)?

    private let componentStack = NSStackView()
    private let scrollView = NSScrollView()
    private let clipView = BreadcrumbClipView()
    private let pathField = NSTextField()
    private let editButton = BrowserToolbarButton()
    private var displayedLocation = BrowserLocation.directory(URL(fileURLWithPath: "/"))
    private var displayedTrail: [BrowserPathComponent]?
    private var outsideClickMonitor: Any?

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
        componentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.contentView = clipView
        scrollView.documentView = componentStack
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clipView.toolTip = "Edit path (Command-L)"
        NSLayoutConstraint.activate([
            componentStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            componentStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            componentStack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            componentStack.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])

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

        clipView.onPrimaryClick = { [weak self] in
            self?.beginEditingPath(nil)
        }
        display(.directory(URL(fileURLWithPath: "/")))
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeOutsideClickMonitor()
        }
    }

    func display(_ location: BrowserLocation, trail: [BrowserPathComponent]? = nil) {
        displayedLocation = location
        displayedTrail = trail
        pathField.stringValue = pathFieldText
        rebuildComponents()
    }

    func display(_ url: URL) {
        display(.directory(url.standardizedFileURL))
    }

    private var pathFieldText: String {
        displayedLocation.directoryURL?.path ?? ""
    }

    func focusAddressField() {
        beginEditingPath(nil)
    }

    var isEditingPath: Bool { !pathField.isHidden }

    private func rebuildComponents() {
        componentStack.arrangedSubviews.forEach {
            componentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if displayedLocation == .computer {
            componentStack.addArrangedSubview(
                makeComponentButton(title: BrowserLocation.computerTitle, location: .computer)
            )
            componentStack.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        if let trail = displayedTrail, !trail.isEmpty {
            for (index, component) in trail.enumerated() {
                if index > 0 { componentStack.addArrangedSubview(makeSeparator()) }
                componentStack.addArrangedSubview(
                    makeComponentButton(title: component.title, location: component.location)
                )
            }
            componentStack.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: NSPoint(x: max(0, componentStack.fittingSize.width - scrollView.contentSize.width), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        guard let displayedURL = displayedLocation.directoryURL else { return }
        let components = displayedURL.pathComponents
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            if index > 0 {
                cursor.appendPathComponent(component, isDirectory: true)
                componentStack.addArrangedSubview(makeSeparator())
            }
            let title = component == "/" ? FileManager.default.displayName(atPath: "/") : component
            componentStack.addArrangedSubview(
                makeComponentButton(title: title, location: .directory(cursor))
            )
        }
        componentStack.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: max(0, componentStack.fittingSize.width - scrollView.contentSize.width), y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeComponentButton(title: String, location: BrowserLocation) -> NSButton {
        let button = BreadcrumbButton(
            title: title,
            location: location,
            target: self,
            action: #selector(selectComponent(_:))
        )
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.lineBreakMode = .byTruncatingMiddle
        button.toolTip = location.directoryURL?.path ?? BrowserLocation.computerTitle
        button.setAccessibilityLabel(
            location == displayedLocation ? "Edit path" : "Go to \(title)"
        )
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
        guard let location = (sender as? BreadcrumbButton)?.location else { return }
        if location == displayedLocation {
            beginEditingPath(nil)
            return
        }
        onNavigate?(location)
    }

    @objc private func beginEditingPath(_ sender: Any?) {
        pathField.stringValue = pathFieldText
        pathField.isHidden = false
        scrollView.isHidden = true
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
        installOutsideClickMonitor()
    }

    private func endEditingPath() {
        guard !pathField.isHidden else { return }
        removeOutsideClickMonitor()
        pathField.stringValue = pathFieldText
        pathField.isHidden = true
        scrollView.isHidden = false
        if let window, window.firstResponder === pathField || window.firstResponder === pathField.currentEditor() {
            window.makeFirstResponder(window)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endEditingPath()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        let owner = Unchecked(value: self)
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            let windowID = event.window.map { ObjectIdentifier($0) }
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                owner.value.endEditingIfClickIsOutside(windowID: windowID, locationInWindow: location)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func endEditingIfClickIsOutside(windowID: ObjectIdentifier?, locationInWindow: NSPoint) {
        guard let window, windowID == ObjectIdentifier(window) else { return }
        let location = convert(locationInWindow, from: nil)
        if !bounds.contains(location) {
            endEditingPath()
        }
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

private final class BreadcrumbButton: BrowserToolbarButton {
    let location: BrowserLocation

    init(title: String, location: BrowserLocation, target: AnyObject?, action: Selector?) {
        self.location = location
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) { nil }
}

private final class BreadcrumbClipView: NSClipView {
    var onPrimaryClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else {
            super.mouseDown(with: event)
            return
        }
        onPrimaryClick?()
    }
}

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}
