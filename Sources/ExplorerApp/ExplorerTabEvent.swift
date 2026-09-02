import ExplorerOperations
import ExplorerUI
import Foundation

enum ExplorerTabEvent {
    case titleChange(String)
    case viewModeChange(BrowserViewMode)
    case previewVisibilityChange(Bool)
    case operationCompleted(FileOperation, FileOperationResult)
    case openLocationInNewTab(BrowserLocation)
    case toggleDualPane
    case removeFavorite(URL)
    case addFavorite(URL)
    case homePageRefresh
    case restorationStateChange
    case viewStateChange(BrowserViewState)
}
