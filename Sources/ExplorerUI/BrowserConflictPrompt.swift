import Foundation

public struct BrowserConflictPrompt: Sendable, Equatable {
    public let sourceName: String
    public let destinationName: String
    public let destinationFolder: String
    public let operationTitle: String
    public let remainingItemCount: Int

    public init(
        sourceName: String,
        destinationName: String,
        destinationFolder: String,
        operationTitle: String,
        remainingItemCount: Int
    ) {
        self.sourceName = sourceName
        self.destinationName = destinationName
        self.destinationFolder = destinationFolder
        self.operationTitle = operationTitle
        self.remainingItemCount = remainingItemCount
    }
}

public enum BrowserConflictChoice: Sendable, Equatable {
    case skip
    case keepBoth
    case replace
    case stop
}

public struct BrowserConflictDecision: Sendable, Equatable {
    public let choice: BrowserConflictChoice
    public let applyToAll: Bool

    public init(choice: BrowserConflictChoice, applyToAll: Bool) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}
