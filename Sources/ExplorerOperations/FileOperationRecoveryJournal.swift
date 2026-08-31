import Foundation

public struct FileOperationRecoveryFailure: Sendable, Equatable {
    public let journalURL: URL
    public let description: String

    public init(journalURL: URL, description: String) {
        self.journalURL = journalURL
        self.description = description
    }
}

public struct FileOperationRecoveryReport: Sendable, Equatable {
    public let restoredDestinations: [URL]
    public let finalizedDestinations: [URL]
    public let failures: [FileOperationRecoveryFailure]

    public init(
        restoredDestinations: [URL] = [],
        finalizedDestinations: [URL] = [],
        failures: [FileOperationRecoveryFailure] = []
    ) {
        self.restoredDestinations = restoredDestinations
        self.finalizedDestinations = finalizedDestinations
        self.failures = failures
    }

    public var didFindPendingWork: Bool {
        !restoredDestinations.isEmpty || !finalizedDestinations.isEmpty || !failures.isEmpty
    }
}

/// A small write-ahead journal for replacement operations. Each transaction
/// records enough information to either restore the original destination or
/// finish deleting its backup after an unexpected termination.
public actor FileOperationRecoveryJournal {
    enum Phase: String, Codable, Sendable {
        case prepared
        case backupCreated
        case replacementCompleted
        case rollbackCompleted
    }

    private struct Entry: Codable, Sendable {
        let id: UUID
        let destination: URL
        let backup: URL
        let startedAt: Date
        var phase: Phase
    }

    private let directory: URL
    private let fileManager: FileManager
    private let coordinator: any FileCoordinationClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.coordinator = SystemFileCoordinationClient()
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func begin(destination: URL, backup: URL) throws -> UUID {
        let entry = Entry(
            id: UUID(),
            destination: destination.standardizedFileURL,
            backup: backup.standardizedFileURL,
            startedAt: Date(),
            phase: .prepared
        )
        try write(entry)
        return entry.id
    }

    func markBackupCreated(_ id: UUID) throws {
        try update(id, phase: .backupCreated)
    }

    func markReplacementCompleted(_ id: UUID) throws {
        try update(id, phase: .replacementCompleted)
    }

    func markRollbackCompleted(_ id: UUID) throws {
        try update(id, phase: .rollbackCompleted)
    }

    func finish(_ id: UUID) throws {
        let url = journalURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func pendingEntryCount() throws -> Int {
        try journalURLs().count
    }

    public func recoverPendingTransactions() -> FileOperationRecoveryReport {
        let urls: [URL]
        do {
            urls = try journalURLs()
        } catch {
            return FileOperationRecoveryReport(
                failures: [.init(journalURL: directory, description: error.localizedDescription)]
            )
        }

        var restored: [URL] = []
        var finalized: [URL] = []
        var failures: [FileOperationRecoveryFailure] = []
        for journalURL in urls {
            do {
                let entry = try read(from: journalURL)
                switch entry.phase {
                case .prepared:
                    if fileManager.fileExists(atPath: entry.backup.path) {
                        try restore(entry)
                        restored.append(entry.destination)
                    } else if !fileManager.fileExists(atPath: entry.destination.path) {
                        throw FileOperationError.underlying(
                            "Both the original destination and its recovery backup are missing."
                        )
                    }
                    try finish(entry.id)
                case .backupCreated:
                    guard fileManager.fileExists(atPath: entry.backup.path) else {
                        throw FileOperationError.underlying("The recovery backup is missing.")
                    }
                    try restore(entry)
                    restored.append(entry.destination)
                    try finish(entry.id)
                case .replacementCompleted:
                    if fileManager.fileExists(atPath: entry.destination.path) {
                        if fileManager.fileExists(atPath: entry.backup.path) {
                            try coordinatedRemove(entry.backup)
                        }
                        finalized.append(entry.destination)
                    } else if fileManager.fileExists(atPath: entry.backup.path) {
                        try restore(entry)
                        restored.append(entry.destination)
                    } else {
                        throw FileOperationError.underlying(
                            "Both the completed replacement and its recovery backup are missing."
                        )
                    }
                    try finish(entry.id)
                case .rollbackCompleted:
                    guard fileManager.fileExists(atPath: entry.destination.path) else {
                        throw FileOperationError.underlying("The restored destination is missing.")
                    }
                    try finish(entry.id)
                }
            } catch {
                failures.append(.init(journalURL: journalURL, description: error.localizedDescription))
            }
        }
        return FileOperationRecoveryReport(
            restoredDestinations: restored,
            finalizedDestinations: finalized,
            failures: failures
        )
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("Explorer", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    private func update(_ id: UUID, phase: Phase) throws {
        let url = journalURL(for: id)
        var entry = try read(from: url)
        entry.phase = phase
        try write(entry)
    }

    private func write(_ entry: Entry) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(entry)
        try data.write(to: journalURL(for: entry.id), options: .atomic)
    }

    private func read(from url: URL) throws -> Entry {
        try decoder.decode(Entry.self, from: Data(contentsOf: url))
    }

    private func journalURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func journalURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func restore(_ entry: Entry) throws {
        if fileManager.fileExists(atPath: entry.destination.path) {
            try coordinatedRemove(entry.destination)
        }
        try coordinator.coordinateMoving(
            from: entry.backup,
            to: entry.destination
        ) { coordinatedBackup, coordinatedDestination in
            try fileManager.moveItem(at: coordinatedBackup, to: coordinatedDestination)
        }
    }

    private func coordinatedRemove(_ url: URL) throws {
        try coordinator.coordinateWriting(at: url, intent: .delete) { coordinatedURL in
            try fileManager.removeItem(at: coordinatedURL)
        }
    }
}
