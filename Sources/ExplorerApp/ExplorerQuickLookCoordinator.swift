import AppKit
@preconcurrency import QuickLookUI

/// Owns the shared Quick Look panel's data source and the current tab's preview
/// selection while responder-chain control remains with the tab controller.
@MainActor
final class ExplorerQuickLookCoordinator: NSObject {
    private weak var owner: NSResponder?
    private var urls: [URL] = []

    init(owner: NSResponder) {
        self.owner = owner
    }

    func updateSelection(_ selection: Set<URL>) {
        urls = selection.sorted { $0.path < $1.path }
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), owns(panel) else { return }
        guard !urls.isEmpty else {
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
        urls = selection.sorted { $0.path < $1.path }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        guard owns(panel) else { return }
        configure(panel)
        panel.reloadData()
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func beginControl(_ panel: QLPreviewPanel, selection: Set<URL>) {
        urls = selection.sorted { $0.path < $1.path }
        configure(panel)
    }

    private func configure(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    private func owns(_ panel: QLPreviewPanel) -> Bool {
        guard let owner else { return false }
        return panel.currentController as? NSResponder === owner
    }
}

extension ExplorerQuickLookCoordinator: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            urls.indices.contains(index) ? urls[index] as NSURL : nil
        }
    }
}
