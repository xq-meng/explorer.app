import Foundation

/// A browser destination. Virtual locations never masquerade as file URLs.
public enum BrowserLocation: Hashable, Sendable, Codable {
    case computer
    case directory(URL)

    public static let computerTitle = "My Computer"

    public init(directoryURL: URL) {
        self = .directory(directoryURL.standardizedFileURL)
    }

    public var directoryURL: URL? {
        guard case let .directory(url) = self else { return nil }
        return url
    }

    public var displayTitle: String {
        switch self {
        case .computer:
            return Self.computerTitle
        case let .directory(url):
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
    }
}
