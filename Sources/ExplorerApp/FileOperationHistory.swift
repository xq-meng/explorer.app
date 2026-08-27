import ExplorerOperations

enum FileOperationHistoryDirection {
    case undo
    case redo

    var statusVerb: String { self == .undo ? "Undoing" : "Redoing" }
    var completedVerb: String { self == .undo ? "Undid" : "Redid" }
    var commandVerb: String { self == .undo ? "undo" : "redo" }
}

struct FileOperationHistory {
    private var undo: [FileOperationUndoPlan] = []
    private var redo: [FileOperationUndoPlan] = []
    private let limit = 100

    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    var undoActionName: String? { undo.last?.actionName }
    var redoActionName: String? { redo.last?.actionName }

    mutating func record(_ plan: FileOperationUndoPlan) {
        undo.append(plan)
        if undo.count > limit { undo.removeFirst(undo.count - limit) }
        redo.removeAll()
    }

    mutating func take(_ direction: FileOperationHistoryDirection) -> FileOperationUndoPlan? {
        direction == .undo ? undo.popLast() : redo.popLast()
    }

    mutating func complete(_ plan: FileOperationUndoPlan, direction: FileOperationHistoryDirection) {
        if direction == .undo { redo.append(plan) } else { undo.append(plan) }
    }

    mutating func restore(_ plan: FileOperationUndoPlan, direction: FileOperationHistoryDirection) {
        if direction == .undo { undo.append(plan) } else { redo.append(plan) }
    }
}
