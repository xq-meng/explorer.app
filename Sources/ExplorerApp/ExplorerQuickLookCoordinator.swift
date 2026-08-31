import AppKit
@preconcurrency import QuickLookUI

/// Owns the shared Quick Look panel's data source and the current tab's preview
/// selection while responder-chain control remains with the window controller.
@MainActor
final class ExplorerQuickLookCoordinator: NSObject {
    private weak var owner: NSResponder?
    private let selection = QuickLookSelectionSnapshot()

    init(owner: NSResponder) {
        self.owner = owner
    }

    func updateSelection(_ selection: Set<URL>) {
        self.selection.replace(with: selection)
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), owns(panel) else { return }
        guard !self.selection.isEmpty else {
            panel.orderOut(nil)
            return
        }
        panel.reloadData()
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), owns(panel) else { return }
        panel.orderOut(nil)
    }

    func toggle(selection: Set<URL>) {
        self.selection.replace(with: selection)
        // Context (and menu-bar) tracking keeps the menu in the responder chain
        // until the current run loop finishes. Showing Quick Look immediately
        // makes `QLPreviewPanel` look at the menu instead of the tab.
        DispatchQueue.main.async { [weak self] in
            self?.togglePanel()
        }
    }

    func beginControl(_ panel: QLPreviewPanel, selection: Set<URL>) {
        self.selection.replace(with: selection)
        configure(panel)
    }

    func endControl(_ panel: QLPreviewPanel) {
        guard owns(panel) else { return }
        panel.dataSource = nil
        panel.delegate = nil
    }

    private func togglePanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !selection.isEmpty else { return }
        configure(panel)
        ownerWindow()?.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    private func ownerWindow() -> NSWindow? {
        (owner as? NSViewController)?.view.window
            ?? (owner as? NSWindowController)?.window
    }

    private func configure(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    private func owns(_ panel: QLPreviewPanel) -> Bool {
        panel.dataSource === self
    }
}

extension ExplorerQuickLookCoordinator: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selection.count
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        selection.url(at: index) as NSURL?
    }
}

/// Quick Look is free to request data-source items outside the main actor.
/// Keep the small URL snapshot synchronized instead of imposing a queue
/// assumption on framework callbacks.
final class QuickLookSelectionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var count: Int {
        lock.withLock { urls.count }
    }

    var isEmpty: Bool {
        lock.withLock { urls.isEmpty }
    }

    func replace(with selection: Set<URL>) {
        let sortedURLs = selection.sorted { $0.path < $1.path }
        lock.withLock { urls = sortedURLs }
    }

    func url(at index: Int) -> URL? {
        lock.withLock {
            urls.indices.contains(index) ? urls[index] : nil
        }
    }
}
