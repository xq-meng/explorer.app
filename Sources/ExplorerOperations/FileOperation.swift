import Foundation

/// The kinds of mutations supported by ``FileOperationEngine``.
public enum FileOperationKind: String, Codable, Sendable, CaseIterable {
    case createFolder
    case rename
    case copy
    case move
    case duplicate
    case trash
}

/// The action to take when an operation's destination already exists.
///
/// `.replace` is deliberately opt-in.  The engine never replaces an item for
/// the default policy.
public enum FileConflictPolicy: String, Codable, Sendable, CaseIterable {
    case fail
    case skip
    case keepBoth
    case replace
}

public struct CreateFolderRequest: Codable, Equatable, Sendable {
    public let parent: URL
    public let name: String
    public let conflictPolicy: FileConflictPolicy

    public init(parent: URL, name: String, conflictPolicy: FileConflictPolicy = .fail) {
        self.parent = parent
        self.name = name
        self.conflictPolicy = conflictPolicy
    }
}

public struct RenameRequest: Codable, Equatable, Sendable {
    public let source: URL
    public let name: String
    public let conflictPolicy: FileConflictPolicy

    public init(source: URL, name: String, conflictPolicy: FileConflictPolicy = .fail) {
        self.source = source
        self.name = name
        self.conflictPolicy = conflictPolicy
    }
}

public struct FileBatchRequest: Codable, Equatable, Sendable {
    public let sources: [URL]
    public let destination: URL
    public let conflictPolicy: FileConflictPolicy

    public init(sources: [URL], destination: URL, conflictPolicy: FileConflictPolicy = .fail) {
        self.sources = sources
        self.destination = destination
        self.conflictPolicy = conflictPolicy
    }
}

public struct DuplicateRequest: Codable, Equatable, Sendable {
    public let source: URL
    public let destination: URL
    public let conflictPolicy: FileConflictPolicy

    public init(source: URL, destination: URL, conflictPolicy: FileConflictPolicy = .fail) {
        self.source = source
        self.destination = destination
        self.conflictPolicy = conflictPolicy
    }
}

public struct TrashRequest: Codable, Equatable, Sendable {
    public let sources: [URL]

    public init(sources: [URL]) {
        self.sources = sources
    }
}

/// A complete, serializable description of one file operation.
public enum FileOperation: Codable, Equatable, Sendable {
    case createFolder(CreateFolderRequest)
    case rename(RenameRequest)
    case copy(FileBatchRequest)
    case move(FileBatchRequest)
    case duplicate(DuplicateRequest)
    case trash(TrashRequest)

    public var kind: FileOperationKind {
        switch self {
        case .createFolder: return .createFolder
        case .rename: return .rename
        case .copy: return .copy
        case .move: return .move
        case .duplicate: return .duplicate
        case .trash: return .trash
        }
    }

    public static func createFolder(at parent: URL, name: String,
                                    conflictPolicy: FileConflictPolicy = .fail) -> Self {
        .createFolder(CreateFolderRequest(parent: parent, name: name, conflictPolicy: conflictPolicy))
    }

    public static func rename(source: URL, name: String,
                              conflictPolicy: FileConflictPolicy = .fail) -> Self {
        .rename(RenameRequest(source: source, name: name, conflictPolicy: conflictPolicy))
    }

    public static func copy(sources: [URL], to destination: URL,
                            conflictPolicy: FileConflictPolicy = .fail) -> Self {
        .copy(FileBatchRequest(sources: sources, destination: destination, conflictPolicy: conflictPolicy))
    }

    public static func move(sources: [URL], to destination: URL,
                            conflictPolicy: FileConflictPolicy = .fail) -> Self {
        .move(FileBatchRequest(sources: sources, destination: destination, conflictPolicy: conflictPolicy))
    }

    public static func duplicate(source: URL, to destination: URL,
                                 conflictPolicy: FileConflictPolicy = .fail) -> Self {
        .duplicate(DuplicateRequest(source: source, destination: destination, conflictPolicy: conflictPolicy))
    }

    public static func duplicate(source: URL, destination: URL,
                                 conflictPolicy: FileConflictPolicy = .fail) -> Self {
        .duplicate(DuplicateRequest(source: source, destination: destination, conflictPolicy: conflictPolicy))
    }

    public static func trash(sources: [URL]) -> Self {
        .trash(TrashRequest(sources: sources))
    }
}

public enum FileOperationItemStatus: String, Codable, Sendable {
    case completed
    case skipped
}

public struct FileOperationItemResult: Codable, Equatable, Sendable {
    public let source: URL
    public let destination: URL?
    public let status: FileOperationItemStatus

    public init(source: URL, destination: URL?, status: FileOperationItemStatus) {
        self.source = source
        self.destination = destination
        self.status = status
    }
}

public struct FileOperationProgress: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let kind: FileOperationKind
    public let completedItems: Int
    public let totalItems: Int
    public let currentItem: URL?
    public let fractionCompleted: Double

    public init(operationID: UUID, kind: FileOperationKind, completedItems: Int,
                totalItems: Int, currentItem: URL? = nil) {
        self.operationID = operationID
        self.kind = kind
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentItem = currentItem
        self.fractionCompleted = totalItems == 0 ? 1 : Double(completedItems) / Double(totalItems)
    }
}

public struct FileOperationResult: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let kind: FileOperationKind
    public let items: [FileOperationItemResult]

    public init(operationID: UUID = UUID(), kind: FileOperationKind,
                items: [FileOperationItemResult]) {
        self.operationID = operationID
        self.kind = kind
        self.items = items
    }

    public var completedItems: Int { items.filter { $0.status == .completed }.count }
    public var skippedItems: Int { items.filter { $0.status == .skipped }.count }
}

public enum FileOperationError: Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidSource(URL)
    case sourceMissing(URL)
    case invalidDestination(URL)
    case destinationMissing(URL)
    case destinationNotDirectory(URL)
    case destinationExists(URL)
    case conflict(URL)
    case invalidName(String)
    case sameSourceAndDestination(URL)
    case cancelled
    case permissionDenied(URL)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let url): return "Invalid source: \(url.path)"
        case .sourceMissing(let url): return "Source does not exist: \(url.path)"
        case .invalidDestination(let url): return "Invalid destination: \(url.path)"
        case .destinationMissing(let url): return "Destination does not exist: \(url.path)"
        case .destinationNotDirectory(let url): return "Destination is not a directory: \(url.path)"
        case .destinationExists(let url): return "Destination already exists: \(url.path)"
        case .conflict(let url): return "Destination conflict: \(url.path)"
        case .invalidName(let name): return "Invalid file name: \(name)"
        case .sameSourceAndDestination(let url): return "Source and destination are the same: \(url.path)"
        case .cancelled: return "Operation cancelled"
        case .permissionDenied(let url): return "Permission denied: \(url.path)"
        case .underlying(let message): return message
        }
    }
}
