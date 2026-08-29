import ExplorerOperations
import ExplorerUI
import Foundation

enum ExplorerTabEvent {
    case titleChange(String)
    case viewModeChange(BrowserViewMode)
    case previewVisibilityChange(Bool)
    case sidebarWidthChange(CGFloat)
    case operationCompleted(FileOperation, FileOperationResult)
    case openLocationInNewTab(BrowserLocation)
    case removeFavorite(URL)
    case addFavorite(URL)
    case homePageRefresh
}
