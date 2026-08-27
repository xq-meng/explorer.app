import AppKit

/// A URL-only drag destination for the collection presentation. Item cells do
/// not inspect or mutate filesystem contents.
final class BrowserDropCollectionView: NSCollectionView {
    var onDrop: ((NSDraggingInfo, IndexPath?) -> NSDragOperation)?
    var onAcceptDrop: ((NSDraggingInfo, IndexPath?) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop?(sender, indexPath(at: sender.draggingLocation)) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop?(sender, indexPath(at: sender.draggingLocation)) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onAcceptDrop?(sender, indexPath(at: sender.draggingLocation)) ?? false
    }

    private func indexPath(at windowPoint: NSPoint) -> IndexPath? {
        indexPathForItem(at: convert(windowPoint, from: nil))
    }
}
