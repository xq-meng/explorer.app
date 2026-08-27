import Foundation
import ExplorerCore

/// A narrow loading facade suited to a tab or outline-controller integration.
/// Keeping it as an actor gives each UI owner a cancellable async boundary without
/// allowing AppKit code to touch `FileManager` directly.
public actor DirectoryLoader {
    private let provider: any FileProviderProtocol

    public init(provider: any FileProviderProtocol = LocalFileProvider()) {
        self.provider = provider
    }

    public func load(
        _ url: URL,
        options: DirectoryLoadOptions = DirectoryLoadOptions()
    ) async throws -> DirectorySnapshot {
        try Task.checkCancellation()
        let snapshot = try await provider.loadDirectory(at: url, options: options)
        try Task.checkCancellation()
        return snapshot
    }
}
