import Foundation
import XCTest
@testable import ExplorerBrowsing

final class NetworkSidebarLocatorTests: XCTestCase {
    func testIncludesICloudDriveWhenTheCloudDocsFolderExists() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        let cloudDocs = NetworkSidebarLocator.iCloudDriveURL(homeURL: home)
        let items = NetworkSidebarLocator.items(homeURL: home) { $0 == cloudDocs }

        XCTAssertEqual(items.map(\.title), ["iCloud Drive"])
        XCTAssertEqual(items.map(\.url), [cloudDocs])
        XCTAssertTrue(cloudDocs.path.hasSuffix("/Library/Mobile Documents/com~apple~CloudDocs"))
    }

    func testOmitsICloudDriveWhenTheCloudDocsFolderIsMissing() {
        let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
        let items = NetworkSidebarLocator.items(homeURL: home) { _ in false }
        XCTAssertTrue(items.isEmpty)
    }
}
