import Foundation
import ExplorerCore

/// Finder's iCloud Drive is a composite folder: files in `com~apple~CloudDocs`
/// plus each app's iCloud library (`…/iCloud~…/Documents`).
public enum ICloudDriveLibraries {
    public static func isCloudDocsDirectory(_ url: URL) -> Bool {
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

    public static func isLibraryDocumentsDirectory(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard url.lastPathComponent == "Documents" else { return false }
        let container = url.deletingLastPathComponent()
        let mobileDocuments = container.deletingLastPathComponent()
        return mobileDocuments.lastPathComponent == "Mobile Documents"
            && container.lastPathComponent != "com~apple~CloudDocs"
    }

    static func mobileDocumentsDirectory(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.lastPathComponent == "Mobile Documents" {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }
        return nil
    }

    public static func cloudDocsDirectory(containing url: URL) -> URL? {
        mobileDocumentsDirectory(containing: url)?
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
    }

    public static func overlayItems(
        at directoryURL: URL,
        fileManager: FileManager = .default,
        showsHiddenFiles: Bool
    ) -> [FileItem] {
        let cloudDocsURL = directoryURL.standardizedFileURL
        guard isCloudDocsDirectory(cloudDocsURL) else { return [] }
        let parent = cloudDocsURL.deletingLastPathComponent()
        let containers: [URL]
        do {
            containers = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.localizedNameKey, .isHiddenKey, .isDirectoryKey],
                options: []
            )
        } catch {
            return []
        }

        var items: [FileItem] = []
        var seen = Set<URL>()
        for container in containers {
            let documentsURL = documentsDirectory(forContainer: container)
            guard seen.insert(documentsURL).inserted else { continue }
            do {
                let containerValues = try container.resourceValues(
                    forKeys: [.localizedNameKey, .isHiddenKey, .isDirectoryKey]
                )
                guard containerValues.isDirectory == true else { continue }
                var isDirectory: ObjCBool = false
                let hasDocuments = fileManager.fileExists(
                    atPath: documentsURL.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
                guard shouldIncludeContainer(
                    container,
                    cloudDocsURL: cloudDocsURL,
                    isHidden: containerValues.isHidden ?? false,
                    hasDocumentsDirectory: hasDocuments,
                    showsHiddenFiles: showsHiddenFiles
                ) else { continue }

                let documentValues = try documentsURL.resourceValues(
                    forKeys: FileSystemMetadata.resourceKeys.union([.localizedNameKey])
                )
                let displayName = displayName(
                    containerName: container.lastPathComponent,
                    containerLocalizedName: containerValues.localizedName,
                    documentsLocalizedName: documentValues.localizedName
                )
                let item = FileSystemMetadata.item(from: documentsURL, values: documentValues, name: displayName)
                if showsHiddenFiles || !item.isHidden {
                    items.append(item)
                }
            } catch {
                continue
            }
        }
        return items
    }

    public static func breadcrumbTrail(for url: URL) -> [(title: String, url: URL)]? {
        let url = url.standardizedFileURL
        guard let mobileDocuments = mobileDocumentsDirectory(containing: url) else { return nil }
        let cloudDocs = mobileDocuments.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        var trail = [(title: NetworkSidebarLocator.iCloudDriveTitle, url: cloudDocs)]

        if isCloudDocsDirectory(url) {
            return trail
        }
        if let relative = relativeComponents(from: cloudDocs, to: url) {
            var cursor = cloudDocs
            for component in relative {
                cursor.appendPathComponent(component, isDirectory: true)
                trail.append((title: component, url: cursor.standardizedFileURL))
            }
            return trail
        }

        guard let documents = libraryDocumentsDirectory(containing: url) else { return nil }
        let container = documents.deletingLastPathComponent()
        trail.append((title: prettyContainerName(container.lastPathComponent), url: documents))
        if let relative = relativeComponents(from: documents, to: url) {
            var cursor = documents
            for component in relative {
                cursor.appendPathComponent(component, isDirectory: true)
                trail.append((title: component, url: cursor.standardizedFileURL))
            }
        }
        return trail
    }

    static func libraryDocumentsDirectory(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if isLibraryDocumentsDirectory(current) { return current }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private static func relativeComponents(from ancestor: URL, to descendant: URL) -> [String]? {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.starts(with: ancestorComponents) else { return nil }
        return Array(descendantComponents.dropFirst(ancestorComponents.count))
    }
}
