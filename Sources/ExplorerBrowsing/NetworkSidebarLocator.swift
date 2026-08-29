import Foundation

/// A sidebar item shown under Network, such as iCloud Drive.
public struct NetworkSidebarItem: Equatable, Sendable {
    public let title: String
    public let url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url.standardizedFileURL
    }
}

/// Resolves network-related locations the sidebar can show without enumerating
/// the disk itself. Callers supply existence checks so tests stay off the live filesystem.
public enum NetworkSidebarLocator {
    public static let iCloudDriveTitle = "iCloud Drive"

    public static func items(homeURL: URL, isDirectory: (URL) -> Bool) -> [NetworkSidebarItem] {
        var items: [NetworkSidebarItem] = []
        let iCloudDrive = iCloudDriveURL(homeURL: homeURL)
        if isDirectory(iCloudDrive) {
            items.append(NetworkSidebarItem(title: iCloudDriveTitle, url: iCloudDrive))
        }
        return items
    }

    public static func iCloudDriveURL(homeURL: URL) -> URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .standardizedFileURL
    }
}
