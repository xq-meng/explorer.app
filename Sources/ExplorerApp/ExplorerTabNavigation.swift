import ExplorerBrowsing
import ExplorerCore
import ExplorerUI
import Foundation

enum ExplorerTabNavigation {
    static func parent(of location: BrowserLocation) -> BrowserLocation? {
        switch location {
        case .computer:
            return nil
        case let .directory(url):
            if ICloudDriveLibraries.isCloudDocsDirectory(url) {
                return .computer
            }
            if ICloudDriveLibraries.isLibraryDocumentsDirectory(url),
               let cloudDocs = ICloudDriveLibraries.cloudDocsDirectory(containing: url) {
                return .directory(cloudDocs)
            }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if url.path == "/" || parent == url {
                return .computer
            }
            return .directory(parent)
        }
    }

    static func breadcrumbTrail(for location: BrowserLocation) -> [BrowserPathComponent]? {
        guard case let .directory(url) = location,
              let trail = ICloudDriveLibraries.breadcrumbTrail(for: url) else {
            return nil
        }
        return trail.map { BrowserPathComponent(title: $0.title, location: .directory($0.url)) }
    }
}

extension BrowserSortDescriptor {
    var fileSortDescriptor: FileSortDescriptor {
        let mappedField: FileSortField = switch field {
        case .name: .name
        case .size: .size
        case .modified: .modificationDate
        case .kind: .kind
        }
        return FileSortDescriptor(
            field: mappedField,
            direction: ascending ? .ascending : .descending,
            directoriesFirst: true
        )
    }
}
