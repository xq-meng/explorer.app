import Foundation

/// The navigation operations exposed by the window chrome.
///
/// The UI intentionally models these commands without assuming a particular
/// file provider. A later coordinator can connect them to navigation history
/// and directory loading services.
public enum BrowserNavigationCommand: Sendable {
    case back
    case forward
    case up
    case refresh
}

/// Commands that operate on the selected file rows. The browser view only
/// routes these intents; the app layer validates and performs mutations.
public enum BrowserFileCommand: Sendable {
    case open
    case openInNewTab
    case revealInFinder
    case newFolder
    case rename
    case copy
    case cut
    case paste
    case duplicate
    case moveToTrash
    case quickLook
}

public enum BrowserDropIntent: Sendable {
    case copy
    case move
}

/// A URL-only drop proposal. UI code extracts no file contents and leaves all
/// filesystem validation and mutation to the app/service layer.
public struct BrowserFileDrop: Sendable {
    public let urls: [URL]
    public let destinationURL: URL?
    public let intent: BrowserDropIntent

    public init(urls: [URL], destinationURL: URL?, intent: BrowserDropIntent) {
        self.urls = urls.map(\.standardizedFileURL)
        self.destinationURL = destinationURL?.standardizedFileURL
        self.intent = intent
    }
}
