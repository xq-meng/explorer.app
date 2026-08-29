import Foundation

/// Finder's iCloud Drive is a composite folder: files in `com~apple~CloudDocs`
/// plus each app's iCloud library (`…/iCloud~…/Documents`).
enum ICloudDriveLibraries {
    static func isCloudDocsDirectory(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return url.lastPathComponent == "com~apple~CloudDocs"
            && url.deletingLastPathComponent().lastPathComponent == "Mobile Documents"
    }

    static func documentsDirectory(forContainer containerURL: URL) -> URL {
        containerURL.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
    }

    static func shouldIncludeContainer(
        _ containerURL: URL,
        cloudDocsURL: URL,
        isHidden: Bool,
        hasDocumentsDirectory: Bool,
        showsHiddenFiles: Bool
    ) -> Bool {
        let container = containerURL.standardizedFileURL
        let cloudDocs = cloudDocsURL.standardizedFileURL
        guard container.deletingLastPathComponent() == cloudDocs.deletingLastPathComponent() else {
            return false
        }
        guard container != cloudDocs else { return false }
        let name = container.lastPathComponent
        if name == ".Trash" { return false }
        if name.hasPrefix("."), !showsHiddenFiles { return false }
        if isHidden, !showsHiddenFiles { return false }
        return hasDocumentsDirectory
    }

    static func displayName(
        containerName: String,
        containerLocalizedName: String?,
        documentsLocalizedName: String?
    ) -> String {
        if let name = sanitizedLocalizedName(containerLocalizedName, rawName: containerName) {
            return name
        }
        if let name = sanitizedLocalizedName(documentsLocalizedName, rawName: "Documents") {
            return name
        }
        return prettyContainerName(containerName)
    }

    static func prettyContainerName(_ raw: String) -> String {
        var parts = raw.split(separator: "~").map(String.init)
        if parts.last?.lowercased() == "icloud" { parts.removeLast() }
        if parts.first?.lowercased() == "icloud" { parts.removeFirst() }
        return parts.last.flatMap { $0.isEmpty ? nil : $0 } ?? raw
    }

    private static func sanitizedLocalizedName(_ name: String?, rawName: String) -> String? {
        guard let name, !name.isEmpty, name != rawName else { return nil }
        return name
    }
}
