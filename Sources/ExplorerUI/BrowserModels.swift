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
    case computer
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

public struct BrowserHomePageItem: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let subtitle: String

    public init(title: String, url: URL, subtitle: String) {
        self.title = title
        self.url = url.standardizedFileURL
        self.subtitle = subtitle
    }
}

public struct BrowserHomePageVolume: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let availableCapacity: Int64?
    public let totalCapacity: Int64?

    public init(
        title: String,
        url: URL,
        availableCapacity: Int64? = nil,
        totalCapacity: Int64? = nil
    ) {
        self.title = title
        self.url = url.standardizedFileURL
        self.availableCapacity = availableCapacity
        self.totalCapacity = totalCapacity
    }

    public var caption: String? {
        BrowserVolumeCapacity.caption(available: availableCapacity, total: totalCapacity)
    }

    public var usedFraction: Double? {
        BrowserVolumeCapacity.usedFraction(available: availableCapacity, total: totalCapacity)
    }
}

public struct BrowserHomePageModel: Sendable, Equatable {
    public var favorites: [BrowserHomePageItem]
    public var volumes: [BrowserHomePageVolume]
    public var network: [BrowserHomePageItem]

    public init(
        favorites: [BrowserHomePageItem] = [],
        volumes: [BrowserHomePageVolume] = [],
        network: [BrowserHomePageItem] = []
    ) {
        self.favorites = favorites
        self.volumes = volumes
        self.network = network
    }

    public static let empty = BrowserHomePageModel()
}

public enum BrowserVolumeCapacity {
    public static func caption(available: Int64?, total: Int64?) -> String? {
        switch (available, total) {
        case let (available?, total?) where total > 0:
            "\(byteCount(available)) free of \(byteCount(total))"
        case let (available?, _):
            "\(byteCount(available)) free"
        case let (_, total?):
            byteCount(total)
        default:
            nil
        }
    }

    public static func usedFraction(available: Int64?, total: Int64?) -> Double? {
        guard let available, let total, total > 0 else { return nil }
        return min(1, max(0, 1 - Double(available) / Double(total)))
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
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
