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
/// the default policy. `.ask` pauses for a ``FileConflictResolving`` decision
/// and behaves like `.fail` when no resolver is provided.
public enum FileConflictPolicy: String, Codable, Sendable, CaseIterable {
    case fail
    case skip
    case keepBoth
    case replace
    case ask
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

    public static func trash(sources: [URL]) -> Self {
        .trash(TrashRequest(sources: sources))
    }

    public var conflictPolicy: FileConflictPolicy? {
        switch self {
        case .createFolder(let request): request.conflictPolicy
        case .rename(let request): request.conflictPolicy
        case .copy(let request), .move(let request): request.conflictPolicy
        case .duplicate(let request): request.conflictPolicy
        case .trash: nil
        }
    }
}

/// A destination clash discovered while executing an operation.
public struct FileConflict: Sendable, Equatable {
    public let source: URL
    public let destination: URL
    public let kind: FileOperationKind
    public let remainingItemCount: Int

    public init(source: URL, destination: URL, kind: FileOperationKind, remainingItemCount: Int) {
        self.source = source
        self.destination = destination
        self.kind = kind
        self.remainingItemCount = remainingItemCount
    }
}

/// The user's choice for one conflicting item.
public enum FileConflictResolution: String, Sendable, Equatable {
    case skip
    case keepBoth
    case replace
    case stop
}

/// Called on the engine's task when ``FileConflictPolicy/ask`` meets an existing destination.
public protocol FileConflictResolving: Sendable {
    func resolve(_ conflict: FileConflict) async -> FileConflictResolution
}

public enum FileOperationItemStatus: String, Codable, Sendable {
    case completed
    case skipped
}

public struct FileOperationItemResult: Codable, Equatable, Sendable {
    public let source: URL
    public let destination: URL?
    public let status: FileOperationItemStatus
    public let replacedExisting: Bool

    public init(
        source: URL,
        destination: URL?,
        status: FileOperationItemStatus,
        replacedExisting: Bool = false
    ) {
        self.source = source
        self.destination = destination
        self.status = status
        self.replacedExisting = replacedExisting
    }
}

public struct FileOperationProgress: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let kind: FileOperationKind
    public let completedItems: Int
    public let totalItems: Int
    public let currentItem: URL?
    public let completedBytes: Int64
    public let totalBytes: Int64?
    public let fractionCompleted: Double

    public init(
        operationID: UUID,
        kind: FileOperationKind,
        completedItems: Int,
        totalItems: Int,
        currentItem: URL? = nil,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil
    ) {
        self.operationID = operationID
        self.kind = kind
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentItem = currentItem
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        if let totalBytes, totalBytes > 0 {
            self.fractionCompleted = min(1, Double(completedBytes) / Double(totalBytes))
        } else {
            self.fractionCompleted = totalItems == 0 ? 1 : Double(completedItems) / Double(totalItems)
        }
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
        case .invalidName(let name): return "Invalid file name: \(name)"
        case .sameSourceAndDestination(let url): return "Source and destination are the same: \(url.path)"
        case .cancelled: return "Operation cancelled"
        case .permissionDenied(let url): return "Permission denied: \(url.path)"
        case .underlying(let message): return message
        }
    }
}
