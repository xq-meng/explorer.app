import Foundation
import XCTest
@testable import ExplorerBrowsing

final class ICloudDriveLibrariesTests: XCTestCase {
    func testRecognizesCloudDocsDirectory() {
        let cloudDocs = URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        XCTAssertTrue(ICloudDriveLibraries.isCloudDocsDirectory(cloudDocs))
        XCTAssertFalse(
            ICloudDriveLibraries.isCloudDocsDirectory(
                cloudDocs.appendingPathComponent("Downloads", isDirectory: true)
            )
        )
        XCTAssertFalse(
            ICloudDriveLibraries.isCloudDocsDirectory(URL(fileURLWithPath: "/Users/demo/Documents", isDirectory: true))
        )
    }

    func testIncludesSiblingAppLibrariesWithDocuments() {
        let cloudDocs = URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let stash = URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/iCloud~ws~stash~icloud", isDirectory: true)
        XCTAssertTrue(
            ICloudDriveLibraries.shouldIncludeContainer(
                stash,
                cloudDocsURL: cloudDocs,
                isHidden: false,
                hasDocumentsDirectory: true,
                showsHiddenFiles: false
            )
        )
        XCTAssertFalse(
            ICloudDriveLibraries.shouldIncludeContainer(
                cloudDocs,
                cloudDocsURL: cloudDocs,
                isHidden: false,
                hasDocumentsDirectory: true,
                showsHiddenFiles: false
            )
        )
        XCTAssertFalse(
            ICloudDriveLibraries.shouldIncludeContainer(
                URL(fileURLWithPath: "/Users/demo/Library/Mobile Documents/.Trash", isDirectory: true),
                cloudDocsURL: cloudDocs,
                isHidden: false,
                hasDocumentsDirectory: true,
                showsHiddenFiles: true
            )
        )
        XCTAssertFalse(
            ICloudDriveLibraries.shouldIncludeContainer(
                stash,
                cloudDocsURL: cloudDocs,
                isHidden: false,
                hasDocumentsDirectory: false,
                showsHiddenFiles: false
            )
        )
    }

    func testDisplayNamePrefersLocalizedAppName() {
        XCTAssertEqual(
            ICloudDriveLibraries.displayName(
                containerName: "iCloud~ws~stash~icloud",
                containerLocalizedName: "Stash",
                documentsLocalizedName: "Documents"
            ),
            "Stash"
        )
        XCTAssertEqual(
            ICloudDriveLibraries.prettyContainerName("iCloud~ws~stash~icloud"),
            "stash"
        )
        XCTAssertEqual(
            ICloudDriveLibraries.prettyContainerName("com~apple~Pages"),
            "Pages"
        )
    }
}

final class FileSystemMetadataCloudTests: XCTestCase {
    func testCloudOnlyRequiresUbiquitousItemThatIsNotDownloaded() {
        XCTAssertTrue(
            FileSystemMetadata.isCloudOnly(
                isUbiquitousItem: true,
                downloadingStatus: .notDownloaded
            )
        )
        XCTAssertFalse(
            FileSystemMetadata.isCloudOnly(
                isUbiquitousItem: true,
                downloadingStatus: .current
            )
        )
        XCTAssertFalse(
            FileSystemMetadata.isCloudOnly(
                isUbiquitousItem: true,
                downloadingStatus: .downloaded
            )
        )
        XCTAssertFalse(
            FileSystemMetadata.isCloudOnly(
                isUbiquitousItem: false,
                downloadingStatus: .notDownloaded
            )
        )
        XCTAssertFalse(
            FileSystemMetadata.isCloudOnly(
                isUbiquitousItem: nil,
                downloadingStatus: nil
            )
        )
    }
}
