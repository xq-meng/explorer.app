import Foundation
import XCTest
@testable import ExplorerCore
@testable import ExplorerBrowsing

final class SearchServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testImmediateSnapshotFilteringHonorsQueryAndHiddenOption() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let snapshot = DirectorySnapshot(directoryURL: root, items: [
            item(named: "Report.txt", in: root),
            item(named: ".report-secret.txt", in: root, hidden: true),
            item(named: "notes.txt", in: root)
        ])
        let service = SearchService()

        let visible = try await service.filter(snapshot, matching: SearchQuery(text: "report"))
        XCTAssertEqual(visible.map(\.name), ["Report.txt"])

        let includingHidden = try await service.filter(
            snapshot,
            matching: SearchQuery(text: "report", includesHiddenFiles: true)
        )
        XCTAssertEqual(includingHidden.map(\.name), [".report-secret.txt", "Report.txt"])
    }

    func testRecursiveSearchHonorsHiddenFilesAndLimit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try makeFile(named: "needle-one.txt", in: root)
        try makeFile(named: ".needle-hidden.txt", in: root)
        let child = root.appendingPathComponent("child", isDirectory: true)
        try fileManager.createDirectory(at: child, withIntermediateDirectories: false)
        try makeFile(named: "needle-two.txt", in: child)
        let service = SearchService()

        let visible = try await service.searchRecursively(at: root, matching: SearchQuery(text: "needle"))
        XCTAssertEqual(visible.map(\.name), ["needle-one.txt", "needle-two.txt"])

        let limited = try await service.searchRecursively(
            at: root,
            matching: SearchQuery(text: "needle", includesHiddenFiles: true, maximumResults: 1)
        )
        XCTAssertEqual(limited.count, 1)
    }

    func testRecursiveSearchDoesNotTraverseSymbolicLinks() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let external = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: external) }
        try makeFile(named: "needle-outside.txt", in: external)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("linked-directory"),
            withDestinationURL: external
        )
        let service = SearchService()

        let results = try await service.searchRecursively(at: root, matching: SearchQuery(text: "needle"))
        XCTAssertTrue(results.isEmpty)
    }

    func testCancelledSearchFailsBeforeEnumeration() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let service = SearchService()
        withUnsafeCurrentTask { $0?.cancel() }

        do {
            _ = try await service.searchRecursively(at: root, matching: SearchQuery(text: "anything"))
            XCTFail("Expected cancellation")
        } catch let error as SearchServiceError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testSpotlightSearchMapsIndexedURLsAndSkipsHiddenDescendants() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try makeFile(named: "needle.txt", in: root)
        let hidden = root.appendingPathComponent(".secret", isDirectory: true)
        try fileManager.createDirectory(at: hidden, withIntermediateDirectories: false)
        try makeFile(named: "needle-hidden.txt", in: hidden)
        let outside = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: outside) }
        try makeFile(named: "needle-outside.txt", in: outside)

        let spotlight = FakeSpotlight(urls: [
            root.appendingPathComponent("needle.txt"),
            hidden.appendingPathComponent("needle-hidden.txt"),
            outside.appendingPathComponent("needle-outside.txt"),
            root
        ])
        let service = SearchService(spotlight: spotlight)
        let results = try await service.search(
            strategy: .spotlight,
            root: root,
            query: SearchQuery(text: "needle")
        )
        XCTAssertEqual(results.map(\.name), ["needle.txt"])
    }

    func testSubtreeSearchFallsBackWhenSpotlightIsEmptyOrUnavailable() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try fileManager.createDirectory(at: child, withIntermediateDirectories: false)
        try makeFile(named: "needle.txt", in: child)

        let emptyIndex = SearchService(spotlight: FakeSpotlight(urls: []))
        let recovered = try await emptyIndex.searchSubtree(at: root, matching: SearchQuery(text: "needle"))
        XCTAssertEqual(recovered.map(\.name), ["needle.txt"])

        let failing = SearchService(spotlight: FakeSpotlight(error: SearchServiceError.unavailable(root, code: 1)))
        let fallback = try await failing.searchSubtree(at: root, matching: SearchQuery(text: "needle"))
        XCTAssertEqual(fallback.map(\.name), ["needle.txt"])
    }

    func testSubtreeSearchKeepsSpotlightHitsWithoutWalkingTheRestOfTheTree() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        try makeFile(named: "needle-indexed.txt", in: root)
        try makeFile(named: "needle-unindexed.txt", in: root)

        let service = SearchService(spotlight: FakeSpotlight(urls: [root.appendingPathComponent("needle-indexed.txt")]))
        let results = try await service.searchSubtree(at: root, matching: SearchQuery(text: "needle"))
        XCTAssertEqual(results.map(\.name), ["needle-indexed.txt"])
    }

    func testSpotlightPredicateEscapesLikeWildcards() {
        XCTAssertEqual(SpotlightMetadataPredicate.likePattern(for: "a*b?c[d]"), "*a\\*b\\?c\\[d]*")
        let predicate = SpotlightMetadataPredicate.make(for: SearchQuery(text: "Report"))
        XCTAssertTrue(predicate.predicateFormat.contains("kMDItemFSName"))
    }

    func testCancelledSpotlightSearchFailsBeforeQueryingTheIndex() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let spotlight = FakeSpotlight(urls: [root.appendingPathComponent("needle.txt")])
        let service = SearchService(spotlight: spotlight)
        withUnsafeCurrentTask { $0?.cancel() }

        do {
            _ = try await service.search(strategy: .spotlight, root: root, query: SearchQuery(text: "needle"))
            XCTFail("Expected cancellation")
        } catch let error as SearchServiceError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(spotlight.wasQueried)
    }
}

private final class FakeSpotlight: SpotlightSearching, @unchecked Sendable {
    let urls: [URL]
    let error: (any Error)?
    private let lock = NSLock()
    private var queried = false

    init(urls: [URL] = [], error: (any Error)? = nil) {
        self.urls = urls
        self.error = error
    }

    var wasQueried: Bool {
        lock.lock()
        defer { lock.unlock() }
        return queried
    }

    func itemURLs(matching query: SearchQuery, scopedTo root: URL) async throws -> [URL] {
        markQueried()
        if let error { throw error }
        return urls
    }

    private nonisolated func markQueried() {
        lock.lock()
        queried = true
        lock.unlock()
    }
}

private extension SearchServiceTests {
    func makeTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func makeFile(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
    }

    func item(named name: String, in directory: URL, hidden: Bool = false) -> FileItem {
        let url = directory.appendingPathComponent(name)
        return FileItem(
            id: FileItemID(volumeIdentifier: nil, resourceIdentifier: nil, fallbackURL: url),
            url: url,
            name: name,
            kind: .file,
            size: nil,
            creationDate: nil,
            modificationDate: nil,
            isHidden: hidden,
            isPackage: false,
            isSymbolicLink: false,
            isReadable: true,
            isWritable: true
        )
    }
}
