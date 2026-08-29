import Foundation

public struct BrowserFileRow: Sendable, Equatable {
    public let url: URL
    public let name: String
    public let modifiedDate: String
    public let size: String
    public let sizeInBytes: Int64?
    public let kind: String
    public let isNavigable: Bool
    public let isHidden: Bool
    public let isCloudOnly: Bool

    public init(
        url: URL,
        name: String,
        modifiedDate: String,
        size: String,
        sizeInBytes: Int64? = nil,
        kind: String,
        isNavigable: Bool,
        isHidden: Bool = false,
        isCloudOnly: Bool = false
    ) {
        self.url = url.standardizedFileURL
        self.name = name
        self.modifiedDate = modifiedDate
        self.size = size
        self.sizeInBytes = sizeInBytes
        self.kind = kind
        self.isNavigable = isNavigable
        self.isHidden = isHidden
        self.isCloudOnly = isCloudOnly
    }
}

public enum BrowserSidebarLocationKind: String, Sendable, Equatable {
    case favorite
    case volume
    case network
    case folder
}

public enum BrowserSortField: String, Sendable, Codable, CaseIterable {
    case name
    case size
    case modified
    case kind
}

public struct BrowserSortDescriptor: Sendable, Codable, Equatable {
    public var field: BrowserSortField
    public var ascending: Bool

    public init(field: BrowserSortField = .name, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    public static let nameAscending = BrowserSortDescriptor()
}

public struct BrowserSidebarLocation: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let kind: BrowserSidebarLocationKind
    public let isRemovable: Bool

    public init(
        title: String,
        url: URL,
        kind: BrowserSidebarLocationKind = .folder,
        isRemovable: Bool = false
    ) {
        self.title = title
        self.url = url.standardizedFileURL
        self.kind = kind
        self.isRemovable = isRemovable
    }
}

struct FileRow {
    let browserRow: BrowserFileRow
    let name: String
    let modifiedDate: String
    let size: String
    let kind: String

    init(_ row: BrowserFileRow) {
        browserRow = row
        name = row.name
        modifiedDate = row.modifiedDate
        size = row.size
        kind = row.kind
    }

    func value(for identifier: String) -> String {
        switch identifier {
        case "name": name
        case "modified": modifiedDate
        case "size": size
        case "kind": kind
        default: ""
        }
    }
}
