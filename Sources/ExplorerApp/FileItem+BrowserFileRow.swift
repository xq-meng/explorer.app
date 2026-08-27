import ExplorerCore
import ExplorerUI
import Foundation

extension BrowserFileRow {
    init(_ item: FileItem) {
        self.init(
            url: item.url,
            name: item.name,
            modifiedDate: item.modificationDate.map {
                DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
            } ?? "—",
            size: item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
            sizeInBytes: item.size,
            kind: item.displayKind,
            isNavigable: item.kind == .directory && !item.isPackage
        )
    }
}

private extension FileItem {
    var displayKind: String {
        switch kind {
        case .directory: "Folder"
        case .file: "File"
        case .package: "Package"
        case .symbolicLink: "Alias"
        case .other: "Other"
        }
    }
}
