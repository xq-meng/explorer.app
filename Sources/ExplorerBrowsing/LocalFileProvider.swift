import Foundation
import ExplorerCore

/// Actor-backed provider for immediate children on the local file system.
/// It deliberately performs no recursive enumeration, so it never follows a symbolic
/// link or descends into a package while loading a directory.
public actor LocalFileProvider: FileProviderProtocol {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func loadDirectory(
        at url: URL,
        options: DirectoryLoadOptions = DirectoryLoadOptions()
    ) async throws -> DirectorySnapshot {
        try checkCancellation()
        let directoryURL = url.standardizedFileURL

        let directoryValues: URLResourceValues
        do {
            directoryValues = try directoryURL.resourceValues(forKeys: [
                .isDirectoryKey, .isPackageKey
            ])
        } catch {
            throw mapDirectoryError(error, url: directoryURL)
        }

        guard directoryValues.isDirectory == true else {
            throw FileProviderError.notDirectory(directoryURL)
        }
        if directoryValues.isPackage == true, !options.allowsPackageNavigation {
            throw FileProviderError.packageNavigationNotAllowed(directoryURL)
        }

        let urls: [URL]
        do {
            // Foundation asks the file system for the requested keys during the
            // enumeration, avoiding a separate attribute lookup for every child.
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(FileSystemMetadata.resourceKeys),
                options: []
            )
        } catch {
            throw mapDirectoryError(error, url: directoryURL)
        }

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        var issues: [DirectoryItemIssue] = []

        for itemURL in urls {
            try checkCancellation()
            do {
                let values = try itemURL.resourceValues(forKeys: FileSystemMetadata.resourceKeys)
                let item = FileSystemMetadata.item(from: itemURL, values: values)
                guard options.showsHiddenFiles || !item.isHidden else { continue }
                items.append(item)
            } catch is CancellationError {
                throw FileProviderError.cancelled
            } catch {
                let details = errorDetails(error)
                issues.append(DirectoryItemIssue(
                    url: itemURL,
                    code: details.code,
                    message: details.message
                ))
            }
        }

        if ICloudDriveLibraries.isCloudDocsDirectory(directoryURL) {
            appendICloudLibraries(
                to: &items,
                issues: &issues,
                cloudDocsURL: directoryURL,
                showsHiddenFiles: options.showsHiddenFiles
            )
        }

        try checkCancellation()
        items.sort(using: options.sortDescriptor)
        return DirectorySnapshot(directoryURL: directoryURL, items: items, issues: issues)
    }
}

private extension LocalFileProvider {
    func checkCancellation() throws {
        if Task.isCancelled {
            throw FileProviderError.cancelled
        }
    }

    func appendICloudLibraries(
        to items: inout [FileItem],
        issues: inout [DirectoryItemIssue],
        cloudDocsURL: URL,
        showsHiddenFiles: Bool
    ) {
        let parent = cloudDocsURL.deletingLastPathComponent()
        let containers: [URL]
        do {
            containers = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.localizedNameKey, .isHiddenKey, .isDirectoryKey],
                options: []
            )
        } catch {
            return
        }

        var seen = Set(items.map(\.url.standardizedFileURL))
        for container in containers {
            do {
                let containerValues = try container.resourceValues(forKeys: [.localizedNameKey, .isHiddenKey, .isDirectoryKey])
                guard containerValues.isDirectory == true else { continue }
                let documentsURL = ICloudDriveLibraries.documentsDirectory(forContainer: container)
                var isDirectory: ObjCBool = false
                let hasDocuments = fileManager.fileExists(atPath: documentsURL.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                guard ICloudDriveLibraries.shouldIncludeContainer(
                    container,
                    cloudDocsURL: cloudDocsURL,
                    isHidden: containerValues.isHidden ?? false,
                    hasDocumentsDirectory: hasDocuments,
                    showsHiddenFiles: showsHiddenFiles
                ) else { continue }
                guard seen.insert(documentsURL).inserted else { continue }

                let documentValues = try documentsURL.resourceValues(forKeys: FileSystemMetadata.resourceKeys.union([.localizedNameKey]))
                let displayName = ICloudDriveLibraries.displayName(
                    containerName: container.lastPathComponent,
                    containerLocalizedName: containerValues.localizedName,
                    documentsLocalizedName: documentValues.localizedName
                )
                let item = FileSystemMetadata.item(from: documentsURL, values: documentValues, name: displayName)
                if showsHiddenFiles || !item.isHidden {
                    items.append(item)
                }
            } catch {
                let details = errorDetails(error)
                issues.append(DirectoryItemIssue(url: container, code: details.code, message: details.message))
            }
        }
    }

    func mapDirectoryError(_ error: Error, url: URL) -> FileProviderError {
        let details = errorDetails(error)
        switch details.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .unavailable(url)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .permissionDenied(url)
        default:
            return .directoryReadFailed(url: url, code: details.code, message: details.message)
        }
    }
}

private func errorDetails(_ error: Error) -> (code: Int, message: String) {
    let nsError = error as NSError
    return (nsError.code, nsError.localizedDescription)
}

private extension Array where Element == FileItem {
    mutating func sort(using descriptor: FileSortDescriptor) {
        sort { lhs, rhs in
            // Grouping is a presentation preference, not a sortable column; folders
            // stay first even when the chosen field is descending.
            if descriptor.directoriesFirst {
                let lhsDirectory = lhs.kind == .directory || lhs.kind == .package
                let rhsDirectory = rhs.kind == .directory || rhs.kind == .package
                if lhsDirectory != rhsDirectory { return lhsDirectory }
            }
            let result = compareFileItems(lhs, rhs, descriptor: descriptor)
            return descriptor.direction == .ascending ? result < 0 : result > 0
        }
    }
}

private func compareFileItems(
    _ lhs: FileItem,
    _ rhs: FileItem,
    descriptor: FileSortDescriptor
) -> Int {
    let primary: Int
    switch descriptor.field {
    case .name:
        primary = comparisonValue(lhs.name.localizedStandardCompare(rhs.name))
    case .kind:
        primary = comparisonValue(lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue))
    case .size:
        primary = compareOptional(lhs.size, rhs.size)
    case .creationDate:
        primary = compareOptional(lhs.creationDate, rhs.creationDate)
    case .modificationDate:
        primary = compareOptional(lhs.modificationDate, rhs.modificationDate)
    }
    if primary != 0 { return primary }

    let nameResult = comparisonValue(lhs.name.localizedStandardCompare(rhs.name))
    if nameResult != 0 { return nameResult }
    return comparisonValue(lhs.url.absoluteString.compare(rhs.url.absoluteString))
}

private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Int {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    case (nil, nil):
        return 0
    case (nil, _):
        return 1
    case (_, nil):
        return -1
    }
}

private func comparisonValue(_ result: ComparisonResult) -> Int {
    switch result {
    case .orderedAscending: return -1
    case .orderedSame: return 0
    case .orderedDescending: return 1
    }
}
