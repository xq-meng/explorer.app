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
