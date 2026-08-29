import Foundation

/// The synthetic My Computer location. It is not a filesystem directory.
public enum BrowserComputerLocation {
    public static let title = "My Computer"
    public static let url = URL(string: "x-explorer-location://computer")!

    public static func matches(_ url: URL) -> Bool {
        url.scheme == "x-explorer-location" && url.host == "computer"
    }
}
