import Foundation

/// The two browser presentations supported by a tab.
public enum BrowserViewMode: String, Sendable, Codable, CaseIterable {
    case details
    case icons
}
