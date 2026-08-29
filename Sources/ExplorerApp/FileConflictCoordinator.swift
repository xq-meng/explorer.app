import AppKit
import ExplorerOperations
import ExplorerUI

actor FileConflictCoordinator: FileConflictResolving {
    private var appliedToAll: FileConflictResolution?
    private let presenter: FileConflictPresenter

    @MainActor
    init(window: NSWindow?) {
        presenter = FileConflictPresenter(window: window)
    }

    func resolve(_ conflict: FileConflict) async -> FileConflictResolution {
        if let appliedToAll { return appliedToAll }

        let prompt = BrowserConflictPrompt(
            sourceName: conflict.source.lastPathComponent,
            destinationName: conflict.destination.lastPathComponent,
            destinationFolder: displayFolderName(for: conflict.destination.deletingLastPathComponent()),
            operationTitle: conflict.kind.displayName,
            remainingItemCount: conflict.remainingItemCount
        )
        let decision = await presenter.present(prompt)
        let resolution = FileConflictResolution(decision.choice)
        if decision.applyToAll {
            appliedToAll = resolution
        }
        return resolution
    }

    private func displayFolderName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

@MainActor
private final class FileConflictPresenter {
    // AppKit ownership remains on the main actor; the coordinator actor owns
    // only the cross-item conflict decision state.
    private weak var window: NSWindow?

    init(window: NSWindow?) {
        self.window = window
    }

    func present(_ prompt: BrowserConflictPrompt) async -> BrowserConflictDecision {
        await BrowserConflictAlert.present(prompt: prompt, in: window)
    }
}

private extension FileConflictResolution {
    init(_ choice: BrowserConflictChoice) {
        switch choice {
        case .skip: self = .skip
        case .keepBoth: self = .keepBoth
        case .replace: self = .replace
        case .stop: self = .stop
        }
    }
}
