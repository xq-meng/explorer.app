import Foundation

/// The two browser presentations supported by a tab.
public enum BrowserViewMode: String, Sendable, Codable, CaseIterable {
    case details
    case icons
}

/// A resilient scroll bookmark for either browser presentation.
///
/// The absolute offset handles an unchanged listing, while the item anchor
/// keeps the same file near the top when items were inserted or removed.
public struct BrowserScrollPosition: Sendable, Codable, Equatable {
    public let anchorURL: URL?
    public let horizontalOffset: Double
    public let verticalOffset: Double
    public let anchorVerticalOffset: Double

    public init(
        anchorURL: URL?,
        horizontalOffset: Double,
        verticalOffset: Double,
        anchorVerticalOffset: Double
    ) {
        self.anchorURL = anchorURL?.standardizedFileURL
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.anchorVerticalOffset = anchorVerticalOffset
    }
}
