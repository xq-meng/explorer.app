import AppKit
import Foundation

public enum FileClipboardIntent: String, Sendable, Codable, Hashable {
    case copy
    case cut
}

public struct FileClipboardContents: Sendable, Hashable {
    public let urls: [URL]
    public let intent: FileClipboardIntent

    public init(urls: [URL], intent: FileClipboardIntent) {
        self.urls = urls
        self.intent = intent
    }
}

public enum FileClipboardError: Error, Sendable, Equatable, LocalizedError {
    case emptySelection
    case nonFileURL(URL)
    case pasteboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "Select at least one local file."
        case let .nonFileURL(url):
            return "Only local file URLs can be placed on the file clipboard: \(url.absoluteString)"
        case .pasteboardWriteFailed:
            return "The system pasteboard could not accept the selected files."
        }
    }
}

/// Main-actor bridge for the system file pasteboard.
///
/// URLs are written with AppKit's standard URL pasteboard support. The only custom
/// payload is a fixed intent string, never a serialized path list; external apps can
/// therefore consume the URLs normally and are treated as a copy source when read.
@MainActor
public final class FileClipboardService {
    public nonisolated static let intentPasteboardType = NSPasteboard.PasteboardType(
        "app.explorer.file-clipboard-intent"
    )
    public nonisolated static let didChangeNotification = Notification.Name(
        "ExplorerFileClipboardDidChange"
    )

    private let pasteboard: any FileClipboardPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = SystemFileClipboardPasteboard(pasteboard: pasteboard)
    }

    public init(backend: any FileClipboardPasteboard) {
        self.pasteboard = backend
    }

    public func copy(_ urls: [URL]) throws {
        try write(urls, intent: .copy)
    }

    public func cut(_ urls: [URL]) throws {
        try write(urls, intent: .cut)
    }

    public func write(_ urls: [URL], intent: FileClipboardIntent) throws {
        let fileURLs = try normalizedFileURLs(urls)
        guard pasteboard.replaceContents(with: fileURLs, intent: intent) else {
            throw FileClipboardError.pasteboardWriteFailed
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Reads ordinary Finder-compatible file URLs. Missing or unrecognized Explorer
    /// intent metadata intentionally defaults to copy for interoperability and safety.
    public func read() -> FileClipboardContents? {
        let urls = uniqueStandardizedFileURLs(pasteboard.readFileURLs())
        guard !urls.isEmpty else { return nil }

        let intent = pasteboard.readIntent() ?? .copy
        return FileClipboardContents(urls: urls, intent: intent)
    }
}

/// Injectable clipboard boundary. Tests can use an in-memory implementation and
/// never need access to the user's pasteboard server.
@MainActor
public protocol FileClipboardPasteboard: AnyObject {
    func replaceContents(with urls: [URL], intent: FileClipboardIntent) -> Bool
    func readFileURLs() -> [URL]
    func readIntent() -> FileClipboardIntent?
}

@MainActor
private final class SystemFileClipboardPasteboard: FileClipboardPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func replaceContents(with urls: [URL], intent: FileClipboardIntent) -> Bool {
        pasteboard.clearContents()
        let items = urls.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index == 0 {
                // The custom representation carries only the operation intent.
                // File locations remain in the standard Finder-compatible type.
                item.setString(intent.rawValue, forType: FileClipboardService.intentPasteboardType)
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }

    func readFileURLs() -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return objects.compactMap { $0 as URL? }
    }

    func readIntent() -> FileClipboardIntent? {
        pasteboard.string(forType: FileClipboardService.intentPasteboardType)
            .flatMap(FileClipboardIntent.init(rawValue:))
    }
}

private extension FileClipboardService {
    func normalizedFileURLs(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { throw FileClipboardError.emptySelection }
        for url in urls where !url.isFileURL {
            throw FileClipboardError.nonFileURL(url)
        }
        let result = uniqueStandardizedFileURLs(urls)
        guard !result.isEmpty else { throw FileClipboardError.emptySelection }
        return result
    }

    func uniqueStandardizedFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.absoluteString).inserted ? standardized : nil
        }
    }
}
