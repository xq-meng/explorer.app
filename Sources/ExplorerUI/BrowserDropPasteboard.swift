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

protocol BrowserDropPasteboardReading {
    var hasFileURLs: Bool { get }
    var hasPromisedFiles: Bool { get }

    func readFileURLs() -> [URL]
    func readPromisedFileReceivers() -> [NSFilePromiseReceiver]
}

public enum BrowserDropPasteboard {
    public static var promisedFileTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    public static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + promisedFileTypes
    }

    public static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        canAccept(AppKitBrowserDropPasteboardReader(pasteboard: pasteboard))
    }

    public static func containsFileURLs(_ pasteboard: NSPasteboard) -> Bool {
        containsFileURLs(AppKitBrowserDropPasteboardReader(pasteboard: pasteboard))
    }

    public static func containsPromisedFiles(_ pasteboard: NSPasteboard) -> Bool {
        containsPromisedFiles(AppKitBrowserDropPasteboardReader(pasteboard: pasteboard))
    }

    public static func read(_ pasteboard: NSPasteboard) -> BrowserDropPayload {
        read(AppKitBrowserDropPasteboardReader(pasteboard: pasteboard))
    }

    static func canAccept(_ reader: any BrowserDropPasteboardReading) -> Bool {
        containsFileURLs(reader) || containsPromisedFiles(reader)
    }

    static func containsFileURLs(_ reader: any BrowserDropPasteboardReading) -> Bool {
        reader.hasFileURLs
    }

    static func containsPromisedFiles(_ reader: any BrowserDropPasteboardReading) -> Bool {
        reader.hasPromisedFiles
    }

    static func read(_ reader: any BrowserDropPasteboardReading) -> BrowserDropPayload {
        let fileURLs = reader.readFileURLs()
        if !fileURLs.isEmpty {
            return BrowserDropPayload(fileURLs: fileURLs, promisedFileReceivers: [])
        }
        return BrowserDropPayload(
            fileURLs: [],
            promisedFileReceivers: reader.readPromisedFileReceivers()
        )
    }
}

private struct AppKitBrowserDropPasteboardReader: BrowserDropPasteboardReading {
    let pasteboard: NSPasteboard

    var hasFileURLs: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    var hasPromisedFiles: Bool {
        pasteboard.availableType(from: BrowserDropPasteboard.promisedFileTypes) != nil
    }

    func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }

    func readPromisedFileReceivers() -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
    }
}
