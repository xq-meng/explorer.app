import AppKit
import ExplorerOperations
import ExplorerUI

final class FileConflictCoordinator: FileConflictResolving, @unchecked Sendable {
    private var appliedToAll: FileConflictResolution?
    @MainActor private weak var window: NSWindow?

    @MainActor
    init(window: NSWindow?) {
        self.window = window
    }

    func resolve(_ conflict: FileConflict) async -> FileConflictResolution {
        if let appliedToAll { return appliedToAll }

        let prompt = BrowserConflictPrompt(
            sourceName: conflict.source.lastPathComponent,
            destinationName: conflict.destination.lastPathComponent,
            destinationFolder: displayFolderName(for: conflict.destination.deletingLastPathComponent()),
            operationTitle: operationTitle(for: conflict.kind),
            remainingItemCount: conflict.remainingItemCount
        )
        let window = await MainActor.run { self.window }
        let decision = await BrowserConflictAlert.present(prompt: prompt, in: window)
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

    private func operationTitle(for kind: FileOperationKind) -> String {
        switch kind {
        case .createFolder: "New Folder"
        case .rename: "Rename"
        case .copy: "Copy"
        case .move: "Move"
        case .duplicate: "Duplicate"
        case .trash: "Move to Trash"
        }
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
