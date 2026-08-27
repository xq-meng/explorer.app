import Foundation
import ExplorerCore

enum FileSystemMetadata {
    static let resourceKeys: Set<URLResourceKey> = [
        .nameKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .isHiddenKey,
        .isReadableKey,
        .isWritableKey,
        .volumeIdentifierKey,
        .fileResourceIdentifierKey
    ]

    static func item(from url: URL, values: URLResourceValues) -> FileItem {
        let isPackage = values.isPackage ?? false
        let isSymbolicLink = values.isSymbolicLink ?? false
        let kind: FileKind
        if isSymbolicLink {
            kind = .symbolicLink
        } else if isPackage {
            kind = .package
        } else if values.isDirectory == true {
            kind = .directory
        } else if values.isRegularFile == true {
            kind = .file
        } else {
            kind = .other
        }

        return FileItem(
            id: FileItemID(url: url, resourceValues: values),
            url: url,
            name: values.name ?? url.lastPathComponent,
            kind: kind,
            size: values.fileSize.map(Int64.init),
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isReadable: values.isReadable ?? false,
            isWritable: values.isWritable ?? false
        )
    }
}
