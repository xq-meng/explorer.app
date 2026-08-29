import ExplorerBrowsing
import ExplorerUI
import Foundation

struct ExplorerNavigationLocations: Equatable {
    let sidebar: [BrowserSidebarLocation]
    let homePage: BrowserHomePageModel

    func contains(_ url: URL) -> Bool {
        sidebar.contains { $0.location == .directory(url.standardizedFileURL) }
    }

    var occupiedDirectoryURLs: Set<URL> {
        Set(sidebar.compactMap(\.directoryURL))
    }
}

enum ExplorerNavigationLocationBuilder {
    static func build(
        homeURL: URL,
        favoriteURLs: [URL],
        mountedVolumes: [MountedVolumeMetadata],
        isDirectory: (URL) -> Bool
    ) -> ExplorerNavigationLocations {
        let homeURL = homeURL.standardizedFileURL
        let standard = standardLocations(homeURL: homeURL, isDirectory: isDirectory)
        let standardURLs = Set(standard.compactMap(\.directoryURL))
        var seenFavoriteURLs = standardURLs
        let custom = favoriteURLs.compactMap { candidate -> BrowserSidebarLocation? in
            let url = candidate.standardizedFileURL
            guard seenFavoriteURLs.insert(url).inserted else { return nil }
            let title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return BrowserSidebarLocation(
                title: title,
                url: url,
                kind: .favorite,
                isRemovable: true
            )
        }

        let volumes = mountedVolumes.compactMap { volume -> BrowserSidebarLocation? in
            guard volume.url.standardizedFileURL != homeURL else { return nil }
            return BrowserSidebarLocation(title: volume.displayName, url: volume.url, kind: .volume)
        }
        let network = NetworkSidebarLocator.items(homeURL: homeURL, isDirectory: isDirectory).map {
            BrowserSidebarLocation(title: $0.title, url: $0.url, kind: .network)
        }

        var sidebar = standard + custom
        var seenLocations = Set(sidebar.map(\.location))
        for location in volumes + network where seenLocations.insert(location.location).inserted {
            sidebar.append(location)
        }

        let favoriteItems = (standard + custom).compactMap { location -> BrowserHomePageItem? in
            guard location.kind == .favorite, let url = location.directoryURL else { return nil }
            return BrowserHomePageItem(title: location.title, url: url, subtitle: url.path)
        }
        let volumeItems = mountedVolumes.compactMap { volume -> BrowserHomePageVolume? in
            guard volume.url.standardizedFileURL != homeURL else { return nil }
            return BrowserHomePageVolume(
                title: volume.displayName,
                url: volume.url,
                availableCapacity: volume.availableCapacity,
                totalCapacity: volume.totalCapacity
            )
        }
        let networkItems = network.compactMap { location -> BrowserHomePageItem? in
            guard let url = location.directoryURL else { return nil }
            return BrowserHomePageItem(title: location.title, url: url, subtitle: url.path)
        }

        return ExplorerNavigationLocations(
            sidebar: sidebar,
            homePage: BrowserHomePageModel(
                favorites: favoriteItems,
                volumes: volumeItems,
                network: networkItems
            )
        )
    }

    private static func standardLocations(
        homeURL: URL,
        isDirectory: (URL) -> Bool
    ) -> [BrowserSidebarLocation] {
        var locations = [
            BrowserSidebarLocation(
                title: BrowserLocation.computerTitle,
                location: .computer,
                kind: .computer
            ),
            BrowserSidebarLocation(title: "Home", url: homeURL, kind: .favorite),
        ]
        for name in ["Desktop", "Documents", "Downloads"] {
            let url = homeURL.appendingPathComponent(name, isDirectory: true)
            if isDirectory(url) {
                locations.append(BrowserSidebarLocation(title: name, url: url, kind: .favorite))
            }
        }
        if let applicationsURL = FileManager.default.urls(
            for: .applicationDirectory,
            in: .localDomainMask
        ).first, isDirectory(applicationsURL) {
            locations.append(
                BrowserSidebarLocation(title: "Applications", url: applicationsURL, kind: .favorite)
            )
        }
        return locations
    }
}
