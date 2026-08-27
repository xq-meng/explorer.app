import AppKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// The source used to render a thumbnail payload.
public enum ThumbnailSource: String, Sendable, Codable, Hashable {
    case quickLook
    case workspaceIcon
}

/// A Sendable image payload suitable for constructing an `NSImage` on the UI actor.
/// The service intentionally returns bytes instead of `NSImage`, which is not safe to
/// pass freely between Swift concurrency domains.
public struct ThumbnailImage: Sendable, Hashable {
    public let data: Data
    public let source: ThumbnailSource
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(data: Data, source: ThumbnailSource, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    @MainActor
    public func makeNSImage() -> NSImage? {
        NSImage(data: data)
    }
}

public enum ThumbnailFallbackPolicy: String, Sendable, Codable, Hashable {
    /// Return the Finder / registered-app icon when Quick Look cannot render an image.
    case workspaceIcon
    /// Surface the Quick Look failure without generating an icon.
    case none
}

public struct ThumbnailRequest: Sendable, Hashable, Codable {
    public let url: URL
    public let maximumPixelSize: Int
    public let scale: Double
    public let fallbackPolicy: ThumbnailFallbackPolicy

    public init(
        url: URL,
        maximumPixelSize: Int = 256,
        scale: Double = 2,
        fallbackPolicy: ThumbnailFallbackPolicy = .workspaceIcon
    ) {
        self.url = url
        self.maximumPixelSize = maximumPixelSize
        self.scale = scale
        self.fallbackPolicy = fallbackPolicy
    }
}

public enum ThumbnailServiceError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case invalidFileURL(URL)
    case invalidMaximumPixelSize(Int)
    case invalidScale(Double)
    case missingItem(URL)
    case symbolicLinkNotSupported(URL)
    case generationFailed(String)
    case iconFallbackFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Thumbnail generation was cancelled."
        case let .invalidFileURL(url):
            return "Thumbnail URLs must be local file URLs: \(url.absoluteString)"
        case let .invalidMaximumPixelSize(size):
            return "Thumbnail size must be positive, got \(size)."
        case let .invalidScale(scale):
            return "Thumbnail scale must be positive, got \(scale)."
        case let .missingItem(url):
            return "The item no longer exists: \(url.path)"
        case let .symbolicLinkNotSupported(url):
            return "Thumbnail generation does not follow symbolic links: \(url.path)"
        case let .generationFailed(message):
            return "Quick Look could not generate a thumbnail: \(message)"
        case let .iconFallbackFailed(url):
            return "No workspace icon could be created for \(url.path)"
        }
    }
}

/// A cancellation-aware Quick Look thumbnail service.
///
/// This service deliberately has no application-level cache. AppKit views can retain
/// images for their own visible-item lifecycle, while the service stays bounded during
/// large directory scrolling operations.
public actor ThumbnailService {
    public init() {}

    public func thumbnail(for request: ThumbnailRequest) async throws -> ThumbnailImage {
        try validate(request)
        try checkCancellation()

        let quickLookRequest = QLThumbnailGenerator.Request(
            fileAt: request.url,
            size: CGSize(
                width: CGFloat(request.maximumPixelSize),
                height: CGFloat(request.maximumPixelSize)
            ),
            scale: CGFloat(request.scale),
            representationTypes: .thumbnail
        )
        let cancellation = GeneratorRequest(generatorRequest: quickLookRequest)

        do {
            let thumbnail = try await withTaskCancellationHandler(operation: {
                try await Self.generateThumbnail(using: cancellation)
            }, onCancel: {
                cancellation.cancel()
            })
            try checkCancellation()
            return thumbnail
        } catch is CancellationError {
            throw ThumbnailServiceError.cancelled
        } catch let error as ThumbnailServiceError {
            throw error
        } catch {
            guard request.fallbackPolicy == .workspaceIcon else {
                throw ThumbnailServiceError.generationFailed(error.localizedDescription)
            }
            try checkCancellation()
            return try await Self.workspaceIcon(for: request.url)
        }
    }
}

private extension ThumbnailService {
    func validate(_ request: ThumbnailRequest) throws {
        guard request.url.isFileURL else {
            throw ThumbnailServiceError.invalidFileURL(request.url)
        }
        guard request.maximumPixelSize > 0 else {
            throw ThumbnailServiceError.invalidMaximumPixelSize(request.maximumPixelSize)
        }
        guard request.scale.isFinite, request.scale > 0 else {
            throw ThumbnailServiceError.invalidScale(request.scale)
        }

        do {
            let values = try request.url.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey
            ])
            if values.isSymbolicLink == true {
                throw ThumbnailServiceError.symbolicLinkNotSupported(request.url)
            }
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw ThumbnailServiceError.missingItem(request.url)
            }
        } catch let error as ThumbnailServiceError {
            throw error
        } catch {
            throw ThumbnailServiceError.missingItem(request.url)
        }
    }

    func checkCancellation() throws {
        if Task.isCancelled {
            throw ThumbnailServiceError.cancelled
        }
    }

    /// Copies the Objective-C Quick Look representation into a Sendable value
    /// before resuming the Swift concurrency continuation.
    static func generateThumbnail(
        using request: GeneratorRequest
    ) async throws -> ThumbnailImage {
        try await withCheckedThrowingContinuation { continuation in
            request.generator.generateBestRepresentation(for: request.request) { representation, error in
                guard let representation else {
                    continuation.resume(throwing: error ?? ThumbnailServiceError.generationFailed("No representation was returned."))
                    return
                }

                let image = representation.cgImage
                guard let data = pngData(for: image) else {
                    continuation.resume(throwing: ThumbnailServiceError.generationFailed(
                        "Quick Look returned an image that could not be encoded."
                    ))
                    return
                }
                continuation.resume(returning: ThumbnailImage(
                    data: data,
                    source: .quickLook,
                    pixelWidth: image.width,
                    pixelHeight: image.height
                ))
            }
        }
    }

    static func pngData(for image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Data(referencing: data)
    }

    static func workspaceIcon(for url: URL) async throws -> ThumbnailImage {
        try await MainActor.run {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            guard let data = image.tiffRepresentation else {
                throw ThumbnailServiceError.iconFallbackFailed(url)
            }
            return ThumbnailImage(
                data: data,
                source: .workspaceIcon,
                pixelWidth: Int(image.size.width.rounded()),
                pixelHeight: Int(image.size.height.rounded())
            )
        }
    }
}

/// Quick Look classes are Objective-C reference types. This private box is the narrow
/// boundary needed to cancel a request from Task's `@Sendable` cancellation handler.
private final class GeneratorRequest: @unchecked Sendable {
    let generator = QLThumbnailGenerator.shared
    let request: QLThumbnailGenerator.Request

    init(generatorRequest: QLThumbnailGenerator.Request) {
        self.request = generatorRequest
    }

    func cancel() {
        generator.cancel(request)
    }
}
