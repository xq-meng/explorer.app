import Darwin
import Dispatch
import Foundation

public struct DirectoryInvalidation: Sendable, Hashable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }
}

public enum DirectoryChangeMonitorError: Error, Equatable, Sendable, LocalizedError {
    case notDirectory(URL)
    case symbolicLinkNotSupported(URL)
    case unavailable(URL, code: Int)

    public var errorDescription: String? {
        switch self {
        case let .notDirectory(url):
            return "Cannot monitor a non-directory URL: \(url.path)"
        case let .symbolicLinkNotSupported(url):
            return "Directory monitoring does not follow symbolic links: \(url.path)"
        case let .unavailable(url, code):
            return "Cannot monitor \(url.path) (POSIX error \(code))."
        }
    }
}

/// Watches one current directory and emits refresh signals, not precise item diffs.
/// Consumers should discard stale snapshots and reload the directory after an event.
public actor DirectoryChangeMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var continuation: AsyncStream<DirectoryInvalidation>.Continuation?

    public init() {}

    deinit {
        source?.cancel()
    }

    /// Starts monitoring `url`, replacing any existing monitored directory.
    /// The stream buffers only the most recent invalidation, preventing event storms
    /// from retaining an unbounded amount of UI work.
    public func invalidations(at url: URL) throws -> AsyncStream<DirectoryInvalidation> {
        stop()
        let directoryURL = url.standardizedFileURL
        try validate(directoryURL)

        let descriptor = open(directoryURL.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw DirectoryChangeMonitorError.unavailable(directoryURL, code: Int(errno))
        }

        let stream = AsyncStream<DirectoryInvalidation>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: DispatchQueue(label: "app.explorer.directory-change-monitor")
        )
        source.setEventHandler { [weak self] in
            Task { await self?.yieldInvalidation(for: directoryURL) }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
        return stream
    }

    /// Safe to invoke repeatedly, including after stream cancellation.
    public func stop() {
        continuation?.finish()
        continuation = nil
        source?.cancel()
        source = nil
    }
}

private extension DirectoryChangeMonitor {
    func validate(_ url: URL) throws {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw DirectoryChangeMonitorError.symbolicLinkNotSupported(url)
            }
            guard values.isDirectory == true else {
                throw DirectoryChangeMonitorError.notDirectory(url)
            }
        } catch let error as DirectoryChangeMonitorError {
            throw error
        } catch {
            throw DirectoryChangeMonitorError.unavailable(url, code: (error as NSError).code)
        }
    }

    func yieldInvalidation(for url: URL) {
        continuation?.yield(DirectoryInvalidation(directoryURL: url))
    }
}
