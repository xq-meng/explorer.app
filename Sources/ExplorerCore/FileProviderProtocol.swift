import Foundation

/// The UI-facing, asynchronous boundary for file providers.
///
/// Implementations must not require the caller to run on a particular actor. This lets
/// AppKit state remain on `MainActor` while filesystem work stays in service actors.
public protocol FileProviderProtocol: Sendable {
    func loadDirectory(
        at url: URL,
        options: DirectoryLoadOptions
    ) async throws -> DirectorySnapshot
}

public enum FileProviderError: Error, Sendable, Equatable, LocalizedError {
    case cancelled
    case notDirectory(URL)
    case packageNavigationNotAllowed(URL)
    case unavailable(URL)
    case permissionDenied(URL)
    case directoryReadFailed(url: URL, code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "The directory load was cancelled."
        case let .notDirectory(url):
            return "\(url.path) is not a directory."
        case let .packageNavigationNotAllowed(url):
            return "Package navigation is disabled for \(url.path)."
        case let .unavailable(url):
            return "\(url.path) is unavailable or no longer exists."
        case let .permissionDenied(url):
            return "Permission was denied for \(url.path)."
        case let .directoryReadFailed(url, _, message):
            return "Unable to read \(url.path): \(message)"
        }
    }
}
