import AppKit

/// Contents of a file-manager drop. File URLs (Finder, in-app drags) take
/// precedence over file promises so move/copy keep the original paths.
/// Safari, Mail, and Photos typically provide promises without file URLs.
public struct BrowserDropPayload {
    public let fileURLs: [URL]
    public let promisedFileReceivers: [NSFilePromiseReceiver]

    public var isEmpty: Bool { fileURLs.isEmpty && promisedFileReceivers.isEmpty }

    public init(fileURLs: [URL], promisedFileReceivers: [NSFilePromiseReceiver]) {
        self.fileURLs = fileURLs.map(\.standardizedFileURL)
        self.promisedFileReceivers = promisedFileReceivers
    }
}

/// A promised-file drop. The UI only forwards the pasteboard receivers; writing
/// files to disk stays in the app layer.
public struct BrowserPromisedFileDrop {
    public let receivers: [NSFilePromiseReceiver]
    public let destinationURL: URL?
    public let intent: BrowserDropIntent

    public init(receivers: [NSFilePromiseReceiver], destinationURL: URL?, intent: BrowserDropIntent) {
        self.receivers = receivers
        self.destinationURL = destinationURL?.standardizedFileURL
        self.intent = intent
    }
}

public enum BrowserDropPasteboard {
    public static var promisedFileTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    public static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + promisedFileTypes
    }

    public static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        containsFileURLs(pasteboard) || containsPromisedFiles(pasteboard)
    }

    public static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    public static func containsPromisedFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: promisedFileTypes) != nil
    }

    public static func read(_ pasteboard: NSPasteboard) -> BrowserDropPayload {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return BrowserDropPayload(fileURLs: fileURLs, promisedFileReceivers: [])
        }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        return BrowserDropPayload(fileURLs: [], promisedFileReceivers: receivers)
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }
}
