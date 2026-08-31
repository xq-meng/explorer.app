import AppKit

/// A URL-only drag destination for the collection presentation. Item cells do
/// not inspect or mutate filesystem contents.
final class BrowserDropCollectionView: NSCollectionView {
    var onDrop: ((NSDraggingInfo, IndexPath?) -> NSDragOperation)?
    var onAcceptDrop: ((NSDraggingInfo, IndexPath?) -> Bool)?
    var onKeyboardCommand: ((BrowserKeyboardCommand) -> Void)?
    private var dropTargetIndexPath: IndexPath?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropProposal(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropProposal(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTarget(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropTarget(nil) }
        return onAcceptDrop?(sender, indexPath(at: sender.draggingLocation)) ?? false
    }

    override func keyDown(with event: NSEvent) {
        if let command = BrowserFileKeyboard.command(from: event) {
            onKeyboardCommand?(command)
            return
        }
        super.keyDown(with: event)
    }

    private func indexPath(at windowPoint: NSPoint) -> IndexPath? {
        indexPathForItem(at: convert(windowPoint, from: nil))
    }

    private func updateDropProposal(for sender: NSDraggingInfo) -> NSDragOperation {
        let indexPath = indexPath(at: sender.draggingLocation)
        let operation = onDrop?(sender, indexPath) ?? []
        setDropTarget(operation.isEmpty ? nil : indexPath)
        return operation
    }

    private func setDropTarget(_ indexPath: IndexPath?) {
        guard dropTargetIndexPath != indexPath else { return }
        if let previous = dropTargetIndexPath {
            item(at: previous)?.highlightState = .none
        }
        dropTargetIndexPath = indexPath
        if let indexPath {
            item(at: indexPath)?.highlightState = .asDropTarget
        }
    }
}
