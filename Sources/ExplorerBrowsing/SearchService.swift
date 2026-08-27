import Foundation
import ExplorerCore

/// The search backends understood by ``SearchService``.
///
/// Spotlight is intentionally represented but not executed in M4: wrapping
/// `NSMetadataQuery` correctly requires a long-lived run-loop owner and a separate
/// authorization/error model. The non-indexed recursive fallback is always available.
public enum SearchStrategy: String, Sendable, Codable, Hashable {
    case immediateDirectory
    case recursiveFileSystem
    case spotlight
}

public struct SearchQuery: Sendable, Codable, Hashable {
    public let text: String
    public let caseSensitive: Bool
    public let includesHiddenFiles: Bool
    public let maximumResults: Int

    public init(
        text: String,
        caseSensitive: Bool = false,
        includesHiddenFiles: Bool = false,
        maximumResults: Int = 1_000
    ) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.includesHiddenFiles = includesHiddenFiles
        self.maximumResults = maximumResults
    }
}

public enum SearchServiceError: Error, Sendable, Equatable, LocalizedError {
    case cancelled
    case emptyQuery
    case invalidResultLimit(Int)
    case rootIsNotDirectory(URL)
    case symbolicLinkRootNotSupported(URL)
    case unavailable(URL, code: Int)
    case unsupportedStrategy(SearchStrategy)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The search was cancelled."
        case .emptyQuery:
            return "Enter text to search for."
        case let .invalidResultLimit(limit):
            return "The result limit must be positive, got \(limit)."
        case let .rootIsNotDirectory(url):
            return "Search root is not a directory: \(url.path)"
        case let .symbolicLinkRootNotSupported(url):
            return "Search does not follow symbolic-link roots: \(url.path)"
        case let .unavailable(url, code):
            return "Cannot search \(url.path) (error \(code))."
        case .unsupportedStrategy(.spotlight):
            return "Spotlight search is not available yet."
        case let .unsupportedStrategy(strategy):
            return "Unsupported search strategy: \(strategy.rawValue)"
        }
    }
}

/// Cancellable name search with an immediate-snapshot path and a robust filesystem
/// fallback for locations that are not indexed by Spotlight.
public actor SearchService {
    public init() {}

    /// Filters one already-loaded directory without further file-system I/O.
    public func filter(
        _ snapshot: DirectorySnapshot,
        matching query: SearchQuery
    ) throws -> [FileItem] {
        try validate(query)
        try checkCancellation()

        let filteredItems = snapshot.items.filter { item in
            (query.includesHiddenFiles || !item.isHidden) && matches(item.name, query: query)
        }
        try checkCancellation()
        return Array(filteredItems.sorted(by: deterministicOrder).prefix(query.maximumResults))
    }

    /// Searches descendants of `root` without traversing symbolic links or packages.
    /// Hidden directories are skipped entirely when hidden files are disabled.
    public func searchRecursively(
        at root: URL,
        matching query: SearchQuery
    ) throws -> [FileItem] {
        try validate(query)
        try checkCancellation()

        let rootURL = root.standardizedFileURL
        try validateRoot(rootURL)
        let keys = FileSystemMetadata.resourceKeys
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw SearchServiceError.unavailable(rootURL, code: 0)
        }

        var results: [FileItem] = []
        results.reserveCapacity(min(query.maximumResults, 64))
        var scanned = 0

        while let itemURL = enumerator.nextObject() as? URL {
            scanned += 1
            if scanned.isMultiple(of: 32) {
                try checkCancellation()
            }

            let values: URLResourceValues
            do {
                values = try itemURL.resourceValues(forKeys: keys)
            } catch {
                // A file can disappear while it is being searched. Continue with the
                // remaining tree rather than failing an otherwise useful result set.
                continue
            }

            let isDirectory = values.isDirectory == true
            let isHidden = values.isHidden ?? itemURL.lastPathComponent.hasPrefix(".")
            let isSymbolicLink = values.isSymbolicLink == true
            let isPackage = values.isPackage == true
            if isSymbolicLink || isPackage || (!query.includesHiddenFiles && isHidden) {
                if isDirectory || isPackage || isSymbolicLink {
                    enumerator.skipDescendants()
                }
                continue
            }

            let item = FileSystemMetadata.item(from: itemURL, values: values)
            if matches(item.name, query: query) {
                results.append(item)
                if results.count >= query.maximumResults { break }
            }
        }

        try checkCancellation()
        return results.sorted(by: deterministicOrder)
    }

    /// Allows callers to select a future backend without coupling UI code to a
    /// particular implementation. M4 ships the first two strategies only.
    public func search(
        strategy: SearchStrategy,
        root: URL,
        query: SearchQuery
    ) throws -> [FileItem] {
        switch strategy {
        case .recursiveFileSystem:
            return try searchRecursively(at: root, matching: query)
        case .spotlight, .immediateDirectory:
            throw SearchServiceError.unsupportedStrategy(strategy)
        }
    }
}

private extension SearchService {
    func validate(_ query: SearchQuery) throws {
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SearchServiceError.emptyQuery
        }
        guard query.maximumResults > 0 else {
            throw SearchServiceError.invalidResultLimit(query.maximumResults)
        }
    }

    func validateRoot(_ root: URL) throws {
        do {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw SearchServiceError.symbolicLinkRootNotSupported(root)
            }
            guard values.isDirectory == true else {
                throw SearchServiceError.rootIsNotDirectory(root)
            }
        } catch let error as SearchServiceError {
            throw error
        } catch {
            throw SearchServiceError.unavailable(root, code: (error as NSError).code)
        }
    }

    func checkCancellation() throws {
        if Task.isCancelled {
            throw SearchServiceError.cancelled
        }
    }

    func matches(_ name: String, query: SearchQuery) -> Bool {
        let options: String.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]
        return name.range(of: query.text, options: options) != nil
    }

    func deterministicOrder(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.url.absoluteString < rhs.url.absoluteString
    }
}
