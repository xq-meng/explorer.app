import XCTest
@testable import ExplorerOperations

@MainActor
final class FileClipboardServiceTests: XCTestCase {
    func testWritesStandardURLsDeduplicatesAndPreservesCutIntent() throws {
        let pasteboard = InMemoryFileClipboardPasteboard()
        let service = FileClipboardService(backend: pasteboard)
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let first = temporaryDirectory.appendingPathComponent("clipboard-first")
        let second = temporaryDirectory.appendingPathComponent("clipboard-second")
        try Data().write(to: first)
        try Data().write(to: second)

        try service.write([first, first, second], intent: .cut)

        XCTAssertEqual(service.read(), FileClipboardContents(urls: [first, second], intent: .cut))
        XCTAssertEqual(pasteboard.urls, [first, second])
    }

    func testSuccessfulWritePublishesClipboardChange() throws {
        let pasteboard = InMemoryFileClipboardPasteboard()
        let service = FileClipboardService(backend: pasteboard)
        let observer = ClipboardChangeObserver()
        NotificationCenter.default.addObserver(
            observer,
            selector: #selector(ClipboardChangeObserver.clipboardDidChange(_:)),
            name: FileClipboardService.didChangeNotification,
            object: service
        )
        defer { NotificationCenter.default.removeObserver(observer) }
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let url = temporaryDirectory.appendingPathComponent("clipboard-change")
        try Data().write(to: url)

        try service.cut([url])

        XCTAssertEqual(observer.changeCount, 1)
    }

    func testExternalFileURLsDefaultToCopy() throws {
        let pasteboard = InMemoryFileClipboardPasteboard()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let url = temporaryDirectory.appendingPathComponent("external-file-url")
        try Data().write(to: url)
        pasteboard.urls = [url]
        pasteboard.intent = nil

        let service = FileClipboardService(backend: pasteboard)
        XCTAssertEqual(service.read(), FileClipboardContents(urls: [url], intent: .copy))
    }

    func testRejectsNonFileURLs() {
        let pasteboard = InMemoryFileClipboardPasteboard()
        let service = FileClipboardService(backend: pasteboard)
        let remote = URL(string: "https://example.com/not-a-file")!

        XCTAssertThrowsError(try service.copy([remote])) { error in
            XCTAssertEqual(error as? FileClipboardError, .nonFileURL(remote))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplorerClipboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

@MainActor
private final class ClipboardChangeObserver: NSObject {
    private(set) var changeCount = 0

    @objc func clipboardDidChange(_ notification: Notification) {
        changeCount += 1
    }
}

@MainActor
private final class InMemoryFileClipboardPasteboard: FileClipboardPasteboard {
    var urls: [URL] = []
    var intent: FileClipboardIntent?

    func replaceContents(with urls: [URL], intent: FileClipboardIntent) -> Bool {
        self.urls = urls
        self.intent = intent
        return true
    }

    func readFileURLs() -> [URL] {
        urls
    }

    func readIntent() -> FileClipboardIntent? {
        intent
    }
}
