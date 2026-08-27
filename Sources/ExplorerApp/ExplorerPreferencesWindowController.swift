import AppKit

@MainActor
final class ExplorerPreferencesWindowController: NSWindowController {
    var onShowsHiddenFilesChange: ((Bool) -> Void)?
    var onShowsPreviewChange: ((Bool) -> Void)?

    private let settings: ExplorerSettingsStore
    private let hiddenFilesButton = NSButton(checkboxWithTitle: "Show hidden files", target: nil, action: nil)
    private let previewButton = NSButton(checkboxWithTitle: "Show preview pane", target: nil, action: nil)

    init(settings: ExplorerSettingsStore) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Explorer Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        syncControls()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Browser")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let explanation = NSTextField(wrappingLabelWithString:
            "These preferences apply to every open Explorer window and new tab."
        )
        explanation.textColor = .secondaryLabelColor

        hiddenFilesButton.target = self
        hiddenFilesButton.action = #selector(changeHiddenFiles(_:))
        hiddenFilesButton.toolTip = "Include dotfiles and items marked hidden in folder listings."
        previewButton.target = self
        previewButton.action = #selector(changePreview(_:))

        let stack = NSStackView(views: [title, explanation, hiddenFilesButton, previewButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        syncControls()
    }

    private func syncControls() {
        hiddenFilesButton.state = settings.showsHiddenFiles ? .on : .off
        previewButton.state = settings.showsPreview ? .on : .off
    }

    @objc private func changeHiddenFiles(_ sender: NSButton) {
        let isVisible = sender.state == .on
        settings.showsHiddenFiles = isVisible
        onShowsHiddenFilesChange?(isVisible)
    }

    @objc private func changePreview(_ sender: NSButton) {
        let isVisible = sender.state == .on
        settings.showsPreview = isVisible
        onShowsPreviewChange?(isVisible)
    }
}
