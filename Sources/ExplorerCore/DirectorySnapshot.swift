import Foundation

public enum FileSortField: String, CaseIterable, Sendable, Codable, Hashable {
    case name
    case kind
    case size
    case creationDate
    case modificationDate
}

public enum SortDirection: String, CaseIterable, Sendable, Codable, Hashable {
    case ascending
    case descending
}

/// A deterministic, UI-selectable directory ordering.
public struct FileSortDescriptor: Hashable, Sendable, Codable {
    public var field: FileSortField
    public var direction: SortDirection
    public var directoriesFirst: Bool

    public init(
        field: FileSortField = .name,
        direction: SortDirection = .ascending,
        directoriesFirst: Bool = true
    ) {
        self.field = field
        self.direction = direction
        self.directoriesFirst = directoriesFirst
    }

    public static let nameAscending = FileSortDescriptor()
}

/// Controls one non-recursive directory load.
public struct DirectoryLoadOptions: Hashable, Sendable, Codable {
    public var showsHiddenFiles: Bool
    public var sortDescriptor: FileSortDescriptor

    /// Package contents are never enumerated as part of a directory load. This setting
    /// only tells consumers whether a package may be selected as a navigation target.
    public var allowsPackageNavigation: Bool

    public init(
        showsHiddenFiles: Bool = false,
        sortDescriptor: FileSortDescriptor = .nameAscending,
        allowsPackageNavigation: Bool = false
    ) {
        self.showsHiddenFiles = showsHiddenFiles
        self.sortDescriptor = sortDescriptor
        self.allowsPackageNavigation = allowsPackageNavigation
    }
}

/// A non-fatal problem encountered while reading one child. The rest of the directory
/// remains useful and a UI may expose these details in a status or error view.
public struct DirectoryItemIssue: Hashable, Sendable, Codable {
    public let url: URL
    public let code: Int
    public let message: String

    public init(url: URL, code: Int, message: String) {
        self.url = url
        self.code = code
        self.message = message
    }
}

/// An immutable result of a single directory read.
public struct DirectorySnapshot: Hashable, Sendable, Codable {
    public let directoryURL: URL
    public let items: [FileItem]
    public let issues: [DirectoryItemIssue]
    public let loadedAt: Date

    public init(
        directoryURL: URL,
        items: [FileItem],
        issues: [DirectoryItemIssue] = [],
        loadedAt: Date = Date()
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.items = items
        self.issues = issues
        self.loadedAt = loadedAt
    }
}
