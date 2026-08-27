import Foundation
import XCTest
@testable import ExplorerCore

final class FileItemIDTests: XCTestCase {
    func testResourceIdentitySurvivesURLLocationChange() {
        let oldURL = URL(fileURLWithPath: "/tmp/old-name")
        let newURL = URL(fileURLWithPath: "/tmp/new-name")
        let oldID = FileItemID(volumeIdentifier: "volume", resourceIdentifier: "resource", fallbackURL: oldURL)
        let newID = FileItemID(volumeIdentifier: "volume", resourceIdentifier: "resource", fallbackURL: newURL)
        XCTAssertEqual(oldID, newID)
    }

    func testMissingResourceIdentityFallsBackToStandardizedURL() {
        let one = FileItemID(volumeIdentifier: nil, resourceIdentifier: nil,
                             fallbackURL: URL(fileURLWithPath: "/tmp/a/../b"))
        let same = FileItemID(volumeIdentifier: nil, resourceIdentifier: nil,
                              fallbackURL: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(one, same)
    }
}
