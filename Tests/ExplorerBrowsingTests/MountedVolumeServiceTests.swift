import Foundation
import XCTest
@testable import ExplorerBrowsing

final class MountedVolumeServiceTests: XCTestCase {
    func testFiltersPseudoVolumesAndRetainsStartupVolume() async throws {
        let root = URL(fileURLWithPath: "/")
        let external = URL(fileURLWithPath: "/Volumes/External")
        let preboot = URL(fileURLWithPath: "/System/Volumes/Preboot")
        let hidden = URL(fileURLWithPath: "/Volumes/Hidden")
        let rootValues = MountedVolumeResourceValues(volumeName: "Startup", volumeUUIDString: "root-id",
                                                      volumeIsInternal: true, volumeIsBrowsable: false)
        let externalValues = MountedVolumeResourceValues(volumeName: "External", volumeUUIDString: "external-id",
                                                          volumeIsLocal: true, volumeIsRemovable: true,
                                                          volumeIsEjectable: true, volumeTotalCapacity: 1000,
                                                          volumeAvailableCapacity: 400)
        let prebootValues = MountedVolumeResourceValues(volumeName: "Preboot", volumeIsBrowsable: true)
        let hiddenValues = MountedVolumeResourceValues(volumeName: "Hidden", volumeIsBrowsable: false)

        let provider = FakeMountedVolumeProvider(urls: [external, preboot, root, hidden], values: [
            root: rootValues, external: externalValues, preboot: prebootValues, hidden: hiddenValues
        ])
        let volumes = try await MountedVolumeService(provider: provider).mountedVolumes()

        XCTAssertEqual(volumes.map(\.url), [root, external])
        XCTAssertEqual(volumes.first?.id, "root-id")
        XCTAssertEqual(volumes.last?.availableCapacity, 400)
        XCTAssertTrue(volumes.last?.isRemovable == true)
    }

    func testMetadataFailureUsesSafeFallbackAndUnavailableIsSkipped() async throws {
        let root = URL(fileURLWithPath: "/")
        let failed = URL(fileURLWithPath: "/Volumes/ReadableButMetadataFailed")
        let unavailable = URL(fileURLWithPath: "/Volumes/Offline")
        let rootValues = MountedVolumeResourceValues(volumeUUIDString: "root")
        let failedValues = MountedVolumeResourceValues(volumeName: "ignored")
        let provider = FakeMountedVolumeProvider(
            urls: [failed, unavailable, root], values: [root: rootValues, failed: failedValues],
            failures: [failed: NSError(domain: "Test", code: 7),
                       unavailable: NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)]
        )
        let volumes = try await MountedVolumeService(provider: provider).mountedVolumes()

        XCTAssertEqual(volumes.map(\.url), [root, failed])
        XCTAssertEqual(volumes.last?.displayName, "ReadableButMetadataFailed")
        XCTAssertEqual(volumes.last?.id, failed.absoluteString)
    }

    func testSortIsDeterministicByNameThenURL() async throws {
        let alphaA = URL(fileURLWithPath: "/Volumes/A/one")
        let alphaB = URL(fileURLWithPath: "/Volumes/B/two")
        let first = MountedVolumeResourceValues(volumeName: "Alpha", volumeUUIDString: "b")
        let second = MountedVolumeResourceValues(volumeName: "Alpha", volumeUUIDString: "a")
        let provider = FakeMountedVolumeProvider(urls: [alphaA, alphaB], values: [alphaA: first, alphaB: second])
        let volumes = try await MountedVolumeService(provider: provider).mountedVolumes()
        XCTAssertEqual(volumes.map(\.url), [alphaA, alphaB])
    }
}

private final class FakeMountedVolumeProvider: MountedVolumeProvider, @unchecked Sendable {
    let urls: [URL]
    let values: [URL: MountedVolumeResourceValues]
    let failures: [URL: Error]

    init(urls: [URL], values: [URL: MountedVolumeResourceValues], failures: [URL: Error] = [:]) {
        self.urls = urls
        self.values = values
        self.failures = failures
    }

    func mountedVolumeURLs(includingResourceValuesForKeys keys: [URLResourceKey],
                           options: FileManager.VolumeEnumerationOptions) throws -> [URL] { urls }

    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> MountedVolumeResourceValues {
        if let error = failures[url] { throw error }
        return values[url] ?? MountedVolumeResourceValues()
    }
}
