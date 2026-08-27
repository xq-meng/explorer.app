import Foundation

/// A stable identity for a file-system item.
///
/// Local file systems normally provide both a volume and file resource identifier.
/// Their pair survives a rename or move on the same volume. When either is unavailable
/// (for example, on a transient or poorly behaved network volume), the standardized URL
/// is used as a safe location-based fallback.
public struct FileItemID: Hashable, Sendable, Codable {
    public let volumeIdentifier: String?
    public let resourceIdentifier: String?
    public let fallbackURL: URL

    private let identity: Identity

    private enum Identity: Hashable, Sendable, Codable {
        case resource(volume: String, resource: String)
        case url(String)
    }

    public init(
        volumeIdentifier: String?,
        resourceIdentifier: String?,
        fallbackURL: URL
    ) {
        self.volumeIdentifier = volumeIdentifier
        self.resourceIdentifier = resourceIdentifier
        self.fallbackURL = fallbackURL.standardizedFileURL

        if let volumeIdentifier, let resourceIdentifier {
            self.identity = .resource(volume: volumeIdentifier, resource: resourceIdentifier)
        } else {
            self.identity = .url(self.fallbackURL.absoluteString)
        }
    }

    public init(url: URL, resourceValues: URLResourceValues) {
        self.init(
            volumeIdentifier: Self.identifierString(resourceValues.volumeIdentifier),
            resourceIdentifier: Self.identifierString(resourceValues.fileResourceIdentifier),
            fallbackURL: url
        )
    }

    public static func == (lhs: FileItemID, rhs: FileItemID) -> Bool {
        lhs.identity == rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
    }

    private static func identifierString(_ value: Any?) -> String? {
        switch value {
        case let value as Data:
            return "data:" + value.base64EncodedString()
        case let value as NSNumber:
            return "number:" + value.stringValue
        case let value as NSString:
            return "string:" + String(value)
        case let value as UUID:
            return "uuid:" + value.uuidString
        case let value as NSURL:
            return value.absoluteString.map { "url:" + $0 }
        case nil:
            return nil
        default:
            // Foundation exposes these identifiers as opaque values. Description is
            // the only portable representation available while retaining Sendable data.
            return "opaque:" + String(describing: value)
        }
    }
}

/// The display-oriented classification of an item. `isPackage` and `isSymbolicLink`
/// are also retained on ``FileItem`` so callers do not lose either facet.
public enum FileKind: String, CaseIterable, Sendable, Codable, Hashable {
    case directory
    case file
    case package
    case symbolicLink
    case other
}

/// Immutable metadata for one immediate child of a directory.
public struct FileItem: Identifiable, Hashable, Sendable, Codable {
    public let id: FileItemID
    public let url: URL
    public let name: String
    public let kind: FileKind
    public let size: Int64?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let isHidden: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isReadable: Bool
    public let isWritable: Bool

    public init(
        id: FileItemID,
        url: URL,
        name: String,
        kind: FileKind,
        size: Int64?,
        creationDate: Date?,
        modificationDate: Date?,
        isHidden: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isReadable: Bool,
        isWritable: Bool
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.kind = kind
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
        self.isWritable = isWritable
    }
}
