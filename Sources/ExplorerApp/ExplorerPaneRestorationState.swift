import ExplorerUI
import Foundation

struct ExplorerPaneRestorationState: Codable, Equatable, Sendable {
    let location: BrowserLocation
    let backHistory: [BrowserLocation]
    let forwardHistory: [BrowserLocation]
    let selection: [URL]
    let viewMode: BrowserViewMode
    let sortDescriptor: BrowserSortDescriptor
    let scrollPosition: BrowserScrollPosition?
}

struct ExplorerDualPaneRestorationState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let panes: [ExplorerPaneRestorationState]
    let activePaneIndex: Int

    init(panes: [ExplorerPaneRestorationState], activePaneIndex: Int) {
        schemaVersion = Self.currentSchemaVersion
        self.panes = panes
        self.activePaneIndex = activePaneIndex
    }

    var isSupported: Bool {
        schemaVersion == Self.currentSchemaVersion && panes.count == 2
    }
}
