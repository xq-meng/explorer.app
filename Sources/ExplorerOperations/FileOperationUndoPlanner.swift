import Foundation

/// A reversible operation plan produced only from mutations that completed.
/// Inverse operations use the same conflict checks and operation queue as
/// forward operations; no undo step silently replaces an existing item.
public struct FileOperationUndoPlan: Equatable, Sendable {
    public let actionName: String
    public let undoOperations: [FileOperation]
    public let redoOperations: [FileOperation]

    public init(actionName: String, undoOperations: [FileOperation], redoOperations: [FileOperation]) {
        self.actionName = actionName
        self.undoOperations = undoOperations
        self.redoOperations = redoOperations
    }
}

public enum FileOperationUndoPlanner {
    public static func plan(
        for operation: FileOperation,
        result: FileOperationResult
    ) -> FileOperationUndoPlan? {
        guard operation.kind == result.kind,
              !usesDestructiveReplacement(operation),
              result.items.allSatisfy({ !$0.replacedExisting }) else { return nil }
        let completed = result.items.filter { $0.status == .completed }
        guard !completed.isEmpty else { return nil }

        let undoOperations: [FileOperation]
        switch operation {
        case .createFolder, .copy, .duplicate:
            let created = completed.compactMap(\.destination)
            guard created.count == completed.count else { return nil }
            undoOperations = [.trash(sources: created)]

        case .rename:
            undoOperations = completed.compactMap { item in
                guard let destination = item.destination else { return nil }
                return .rename(source: destination, name: item.source.lastPathComponent, conflictPolicy: .fail)
            }
            guard undoOperations.count == completed.count else { return nil }

        case .move, .trash:
            var inverse: [FileOperation] = []
            for item in completed {
                guard let destination = item.destination else { return nil }
                let originalParent = item.source.deletingLastPathComponent()
                inverse.append(.move(sources: [destination], to: originalParent, conflictPolicy: .fail))
                if destination.lastPathComponent != item.source.lastPathComponent {
                    let movedURL = originalParent.appendingPathComponent(destination.lastPathComponent)
                    inverse.append(.rename(
                        source: movedURL,
                        name: item.source.lastPathComponent,
                        conflictPolicy: .fail
                    ))
                }
            }
            undoOperations = inverse

        case .delete:
            return nil
        }

        guard !undoOperations.isEmpty else { return nil }
        return FileOperationUndoPlan(
            actionName: actionName(for: operation.kind),
            undoOperations: undoOperations,
            redoOperations: [operation]
        )
    }

    private static func usesDestructiveReplacement(_ operation: FileOperation) -> Bool {
        switch operation {
        case .createFolder(let request): request.conflictPolicy == .replace
        case .rename(let request): request.conflictPolicy == .replace
        case .copy(let request), .move(let request): request.conflictPolicy == .replace
        case .duplicate(let request): request.conflictPolicy == .replace
        case .trash: false
        case .delete: true
        }
    }

    private static func actionName(for kind: FileOperationKind) -> String {
        switch kind {
        case .createFolder: "New Folder"
        case .rename: "Rename"
        case .copy: "Copy"
        case .move: "Move"
        case .duplicate: "Duplicate"
        case .trash: "Move to Trash"
        case .delete: "Delete"
        }
    }
}
