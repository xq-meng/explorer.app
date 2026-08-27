import Foundation

/// Immutable metadata used by the sidebar for one mounted volume.
public struct MountedVolumeMetadata: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let displayName: String
    public let isLocal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isReadOnly: Bool
    public let isInternal: Bool
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?

    public init(id: String, url: URL, displayName: String,
                isLocal: Bool = true, isRemovable: Bool = false,
                isEjectable: Bool = false, isReadOnly: Bool = false,
                isInternal: Bool = false, totalCapacity: Int64? = nil,
                availableCapacity: Int64? = nil) {
        self.id = id
        self.url = url.standardizedFileURL
        self.displayName = displayName
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isReadOnly = isReadOnly
        self.isInternal = isInternal
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}

public enum MountedVolumeServiceError: Error, Codable, Equatable, Sendable, LocalizedError {
    case enumerationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .enumerationFailed(let message): return "Unable to enumerate mounted volumes: \(message)"
        }
    }
}

public struct MountedVolumeResourceValues: Sendable, Equatable {
    public var volumeName: String?
    public var volumeUUIDString: String?
    public var volumeIsLocal: Bool?
    public var volumeIsRemovable: Bool?
    public var volumeIsEjectable: Bool?
    public var volumeIsReadOnly: Bool?
    public var volumeIsInternal: Bool?
    public var volumeTotalCapacity: Int?
    public var volumeAvailableCapacity: Int?
    public var volumeIsBrowsable: Bool?
    public var isVolume: Bool?

    public init(volumeName: String? = nil, volumeUUIDString: String? = nil,
                volumeIsLocal: Bool? = nil, volumeIsRemovable: Bool? = nil,
                volumeIsEjectable: Bool? = nil, volumeIsReadOnly: Bool? = nil,
                volumeIsInternal: Bool? = nil, volumeTotalCapacity: Int? = nil,
                volumeAvailableCapacity: Int? = nil, volumeIsBrowsable: Bool? = nil,
                isVolume: Bool? = nil) {
        self.volumeName = volumeName
        self.volumeUUIDString = volumeUUIDString
        self.volumeIsLocal = volumeIsLocal
        self.volumeIsRemovable = volumeIsRemovable
        self.volumeIsEjectable = volumeIsEjectable
        self.volumeIsReadOnly = volumeIsReadOnly
        self.volumeIsInternal = volumeIsInternal
        self.volumeTotalCapacity = volumeTotalCapacity
        self.volumeAvailableCapacity = volumeAvailableCapacity
        self.volumeIsBrowsable = volumeIsBrowsable
        self.isVolume = isVolume
    }
}

/// Filesystem access needed by ``MountedVolumeService``. A fake provider can be
/// supplied to tests without reading the machine's actual mounted volumes.
public protocol MountedVolumeProvider: Sendable {
    func mountedVolumeURLs(includingResourceValuesForKeys keys: [URLResourceKey],
                           options: FileManager.VolumeEnumerationOptions) throws -> [URL]
    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> MountedVolumeResourceValues
}

public struct LocalMountedVolumeProvider: MountedVolumeProvider, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func mountedVolumeURLs(includingResourceValuesForKeys keys: [URLResourceKey],
                                  options: FileManager.VolumeEnumerationOptions) throws -> [URL] {
        fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: options) ?? []
    }

    public func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> MountedVolumeResourceValues {
        let values = try url.resourceValues(forKeys: keys)
        return MountedVolumeResourceValues(
            volumeName: values.volumeName,
            volumeUUIDString: values.volumeUUIDString,
            volumeIsLocal: values.volumeIsLocal,
            volumeIsRemovable: values.volumeIsRemovable,
            volumeIsEjectable: values.volumeIsEjectable,
            volumeIsReadOnly: values.volumeIsReadOnly,
            volumeIsInternal: values.volumeIsInternal,
            volumeTotalCapacity: values.volumeTotalCapacity,
            volumeAvailableCapacity: values.volumeAvailableCapacity,
            volumeIsBrowsable: values.volumeIsBrowsable,
            isVolume: values.isVolume
        )
    }
}

/// Actor-backed mounted-volume discovery for sidebar consumers.
public actor MountedVolumeService {
    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeIsLocalKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey,
        .volumeIsInternalKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
        .isVolumeKey
    ]

    private let provider: any MountedVolumeProvider

    public init(provider: any MountedVolumeProvider = LocalMountedVolumeProvider()) {
        self.provider = provider
    }

    public func mountedVolumes() async throws -> [MountedVolumeMetadata] {
        let urls: [URL]
        do {
            urls = try provider.mountedVolumeURLs(
                includingResourceValuesForKeys: Array(Self.resourceKeys),
                options: [.skipHiddenVolumes]
            )
        } catch {
            throw MountedVolumeServiceError.enumerationFailed((error as NSError).localizedDescription)
        }

        var volumes: [MountedVolumeMetadata] = []
        var seenIDs = Set<String>()
        for url in urls {
            let standardizedURL = url.standardizedFileURL
            // Apply path-level pseudo-volume filtering before metadata access;
            // an inaccessible pseudo-volume must not reappear via fallback
            // metadata below.
            if standardizedURL.path != "/", isSystemPseudoVolume(standardizedURL) { continue }
            let values: MountedVolumeResourceValues
            do {
                values = try provider.resourceValues(for: standardizedURL, keys: Self.resourceKeys)
            } catch {
                if standardizedURL.path != "/", isUnavailable(error) { continue }
                // Keep an inaccessible volume visible with safe fallback
                // metadata. It can disappear naturally on the next refresh.
                let fallback = fallbackMetadata(for: standardizedURL)
                if seenIDs.insert(fallback.id).inserted { volumes.append(fallback) }
                continue
            }
            guard shouldInclude(url: standardizedURL, values: values) else { continue }
            let metadata = metadata(for: standardizedURL, values: values)
            if seenIDs.insert(metadata.id).inserted { volumes.append(metadata) }
        }

        volumes.sort { lhs, rhs in
            // Keep the startup volume in the conventional first position.
            let lhsRoot = lhs.url.path == "/"
            let rhsRoot = rhs.url.path == "/"
            if lhsRoot != rhsRoot { return lhsRoot }
            let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if lhs.url.path != rhs.url.path { return lhs.url.path < rhs.url.path }
            return lhs.id < rhs.id
        }
        return volumes
    }

    public func load() async throws -> [MountedVolumeMetadata] {
        try await mountedVolumes()
    }

    private func metadata(for url: URL, values: MountedVolumeResourceValues) -> MountedVolumeMetadata {
        MountedVolumeMetadata(
            id: values.volumeUUIDString ?? url.absoluteString,
            url: url,
            displayName: values.volumeName?.isEmpty == false ? values.volumeName! : fallbackName(for: url),
            isLocal: values.volumeIsLocal ?? true,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isInternal: values.volumeIsInternal ?? (url.path == "/"),
            totalCapacity: values.volumeTotalCapacity.map(Int64.init),
            availableCapacity: values.volumeAvailableCapacity.map(Int64.init)
        )
    }

    private func fallbackMetadata(for url: URL) -> MountedVolumeMetadata {
        MountedVolumeMetadata(id: url.absoluteString, url: url,
                              displayName: fallbackName(for: url), isInternal: url.path == "/")
    }

    private func fallbackName(for url: URL) -> String {
        url.path == "/" ? "/" : (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
    }

    private func shouldInclude(url: URL, values: MountedVolumeResourceValues) -> Bool {
        let isRoot = url.path == "/"
        if values.isVolume == false && !isRoot { return false }
        if values.volumeIsBrowsable == false && !isRoot { return false }
        // APFS exposes implementation volumes (Preboot, VM, Recovery, Update)
        // as mounts. They are not useful sidebar locations. Never apply this
        // path filter to `/`, which is the startup volume users must retain.
        if !isRoot && isSystemPseudoVolume(url) { return false }
        return true
    }

    private func isSystemPseudoVolume(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/private/var/vm" || path.hasPrefix("/System/Volumes/")
    }

    private func isUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == 2) // ENOENT
    }
}
