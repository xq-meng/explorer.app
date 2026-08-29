import ExplorerUI
import Foundation

enum ExplorerOpenURLResolver {
    static func locations(for urls: [URL]) -> [BrowserLocation] {
        var seen = Set<BrowserLocation>()
        var locations: [BrowserLocation] = []
        for url in urls where url.isFileURL {
            let location = location(for: url)
            if seen.insert(location).inserted {
                locations.append(location)
            }
        }
        return locations
    }

    static func location(for url: URL) -> BrowserLocation {
        .directory(browsingDirectory(for: url.standardizedFileURL))
    }

    private static func browsingDirectory(for url: URL) -> URL {
        if isDirectory(url) {
            return url
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if parent.path.isEmpty || parent == url {
            return url
        }
        return parent
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        if let isDirectory = values?.isDirectory {
            return isDirectory
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        return url.hasDirectoryPath
    }
}
