import Foundation

public struct FileOperationFingerprint: Codable, Sendable, Equatable {
    public let volumeNumber: UInt64?
    public let fileNumber: UInt64?
    public let fileSize: UInt64?
    public let modificationDate: Date?
    public let isDirectory: Bool
    public let treeSignature: UInt64?

    public init(
        volumeNumber: UInt64?,
        fileNumber: UInt64?,
        fileSize: UInt64?,
        modificationDate: Date?,
        isDirectory: Bool,
        treeSignature: UInt64? = nil
    ) {
        self.volumeNumber = volumeNumber
        self.fileNumber = fileNumber
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.treeSignature = treeSignature
    }

    static func capture(at url: URL, fileManager: FileManager = .default) throws -> Self {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
        return Self(
            volumeNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            isDirectory: isDirectory,
            treeSignature: isDirectory ? try directoryTreeSignature(at: url, fileManager: fileManager) : nil
        )
    }

    private static func directoryTreeSignature(at root: URL, fileManager: FileManager) throws -> UInt64 {
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw FileOperationError.underlying("Unable to inspect the source directory tree.")
        }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for case let itemURL as URL in enumerator {
            let relativePath = String(itemURL.path.dropFirst(root.path.count))
            for byte in relativePath.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            let attributes = try fileManager.attributesOfItem(atPath: itemURL.path)
            let values: [UInt64] = [
                (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                (attributes[.modificationDate] as? Date)
                    .map { $0.timeIntervalSinceReferenceDate.bitPattern } ?? 0,
            ]
            for value in values {
                hash = (hash ^ value) &* 1_099_511_628_211
            }
            if (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
            }
        }
        if let traversalError { throw traversalError }
        return hash
    }
}

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
    public let discardedTransfers: [URL]
    public let completedTransfers: [URL]
    public let failures: [FileOperationRecoveryFailure]

    public init(
        restoredDestinations: [URL] = [],
        finalizedDestinations: [URL] = [],
        discardedTransfers: [URL] = [],
        completedTransfers: [URL] = [],
        failures: [FileOperationRecoveryFailure] = []
    ) {
        self.restoredDestinations = restoredDestinations
        self.finalizedDestinations = finalizedDestinations
        self.discardedTransfers = discardedTransfers
        self.completedTransfers = completedTransfers
        self.failures = failures
    }

    public var didFindPendingWork: Bool {
        !restoredDestinations.isEmpty
            || !finalizedDestinations.isEmpty
            || !discardedTransfers.isEmpty
            || !completedTransfers.isEmpty
            || !failures.isEmpty
    }
}

/// A write-ahead journal for replacements and staged transfers. Each record
/// carries filesystem identity evidence so recovery never deletes a path that
/// has since been replaced by another client.
public actor FileOperationRecoveryJournal {
    enum TransactionKind: String, Codable, Sendable {
        case replacement
        case replacementMove
        case stagedCopy
        case stagedMove
    }

    enum Phase: String, Codable, Sendable {
        case prepared
        case backupCreated
        case replacementCompleted
        case rollbackCompleted
        case stagedCopyCompleted
        case destinationCommitted
        case sourceDeletionPrepared
        case sourceRemoved
        case sourceMovePrepared
    }

    private struct Entry: Codable, Sendable {
        let schemaVersion: Int?
        let id: UUID
        /// Missing in journals written before 0.8.0; those entries are
        /// replacement transactions.
        let kind: TransactionKind?
        let source: URL?
        let destination: URL
        let staging: URL?
        let backup: URL?
        var sourceFingerprint: FileOperationFingerprint?
        var stagingFingerprint: FileOperationFingerprint?
        let originalDestinationFingerprint: FileOperationFingerprint?
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

    func begin(id: UUID = UUID(), destination: URL, backup: URL) throws -> UUID {
        let entry = Entry(
            schemaVersion: 2,
            id: id,
            kind: .replacement,
            source: nil,
            destination: destination.standardizedFileURL,
            staging: nil,
            backup: backup.standardizedFileURL,
            sourceFingerprint: nil,
            stagingFingerprint: nil,
            originalDestinationFingerprint: nil,
            startedAt: Date(),
            phase: .prepared
        )
        try write(entry)
        return entry.id
    }

    func beginStagedTransfer(
        id: UUID = UUID(),
        source: URL,
        destination: URL,
        staging: URL,
        backup: URL?,
        originalDestinationFingerprint: FileOperationFingerprint?,
        removesSource: Bool
    ) throws -> UUID {
        let entry = Entry(
            schemaVersion: 2,
            id: id,
            kind: removesSource ? .stagedMove : .stagedCopy,
            source: source.standardizedFileURL,
            destination: destination.standardizedFileURL,
            staging: staging.standardizedFileURL,
            backup: backup?.standardizedFileURL,
            sourceFingerprint: nil,
            stagingFingerprint: nil,
            originalDestinationFingerprint: originalDestinationFingerprint,
            startedAt: Date(),
            phase: .prepared
        )
        try write(entry)
        return entry.id
    }

    func beginReplacementMove(
        id: UUID = UUID(),
        source: URL,
        destination: URL,
        backup: URL,
        sourceFingerprint: FileOperationFingerprint,
        originalDestinationFingerprint: FileOperationFingerprint
    ) throws -> UUID {
        let entry = Entry(
            schemaVersion: 2,
            id: id,
            kind: .replacementMove,
            source: source.standardizedFileURL,
            destination: destination.standardizedFileURL,
            staging: nil,
            backup: backup.standardizedFileURL,
            sourceFingerprint: sourceFingerprint,
            stagingFingerprint: nil,
            originalDestinationFingerprint: originalDestinationFingerprint,
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

    func markStagedCopyCompleted(
        _ id: UUID,
        sourceFingerprint: FileOperationFingerprint,
        stagingFingerprint: FileOperationFingerprint
    ) throws {
        try update(id) { entry in
            entry.sourceFingerprint = sourceFingerprint
            entry.stagingFingerprint = stagingFingerprint
            entry.phase = .stagedCopyCompleted
        }
    }

    func markDestinationCommitted(_ id: UUID) throws {
        try update(id, phase: .destinationCommitted)
    }

    func markSourceDeletionPrepared(_ id: UUID) throws {
        try update(id, phase: .sourceDeletionPrepared)
    }

    func markSourceRemoved(_ id: UUID) throws {
        try update(id, phase: .sourceRemoved)
    }

    func markSourceMovePrepared(_ id: UUID) throws {
        try update(id, phase: .sourceMovePrepared)
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
        var discardedTransfers: [URL] = []
        var completedTransfers: [URL] = []
        var failures: [FileOperationRecoveryFailure] = []
        for journalURL in urls {
            do {
                let entry = try read(from: journalURL)
                guard entry.schemaVersion == nil || entry.schemaVersion == 2 else {
                    throw FileOperationError.underlying(
                        "The recovery record uses an unsupported schema version."
                    )
                }
                if entry.schemaVersion == 2 {
                    guard entry.kind != nil else {
                        throw FileOperationError.underlying(
                            "The recovery record has no transaction kind."
                        )
                    }
                    try validateTransactionPaths(entry)
                }
                switch entry.kind ?? .replacement {
                case .replacement:
                    let outcome = try recoverReplacement(entry)
                    restored.append(contentsOf: outcome.restored)
                    finalized.append(contentsOf: outcome.finalized)
                case .replacementMove:
                    let outcome = try recoverReplacementMove(entry)
                    restored.append(contentsOf: outcome.restored)
                    finalized.append(contentsOf: outcome.finalized)
                case .stagedCopy, .stagedMove:
                    if fingerprint(entry.stagingFingerprint, matches: entry.destination) {
                        try completeTransfer(entry)
                        completedTransfers.append(entry.destination)
                    } else {
                        switch entry.phase {
                        case .prepared, .backupCreated:
                            try discardIncompleteTransfer(entry)
                            discardedTransfers.append(entry.destination)
                        case .stagedCopyCompleted where entry.backup != nil:
                            try discardIncompleteTransfer(entry)
                            discardedTransfers.append(entry.destination)
                        case .stagedCopyCompleted, .destinationCommitted, .sourceDeletionPrepared, .sourceRemoved:
                            try completeTransfer(entry)
                            completedTransfers.append(entry.destination)
                        case .replacementCompleted, .rollbackCompleted, .sourceMovePrepared:
                            throw FileOperationError.underlying(
                                "The transfer recovery record contains an invalid phase."
                            )
                        }
                    }
                }
                try finish(entry.id)
            } catch {
                failures.append(.init(journalURL: journalURL, description: error.localizedDescription))
            }
        }
        return FileOperationRecoveryReport(
            restoredDestinations: restored,
            finalizedDestinations: finalized,
            discardedTransfers: discardedTransfers,
            completedTransfers: completedTransfers,
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
        try update(id) { $0.phase = phase }
    }

    private func update(_ id: UUID, mutation: (inout Entry) -> Void) throws {
        let url = journalURL(for: id)
        var entry = try read(from: url)
        mutation(&entry)
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

    private func validateTransactionPaths(_ entry: Entry) throws {
        let parent = entry.destination.deletingLastPathComponent().standardizedFileURL
        switch entry.kind {
        case .stagedCopy, .stagedMove:
            guard let staging = entry.staging,
                  staging.deletingLastPathComponent().standardizedFileURL == parent,
                  staging.lastPathComponent == ".explorer-stage-\(entry.id.uuidString)" else {
                throw FileOperationError.underlying("The transfer recovery record has an invalid staging path.")
            }
            if let backup = entry.backup {
                guard backup.deletingLastPathComponent().standardizedFileURL == parent,
                      backup.lastPathComponent == ".explorer-replace-\(entry.id.uuidString)" else {
                    throw FileOperationError.underlying("The transfer recovery record has an invalid backup path.")
                }
            }
        case .replacementMove:
            guard let backup = entry.backup,
                  backup.deletingLastPathComponent().standardizedFileURL == parent,
                  backup.lastPathComponent == ".explorer-replace-\(entry.id.uuidString)" else {
                throw FileOperationError.underlying("The replacement move record has an invalid backup path.")
            }
        case .replacement:
            guard let backup = entry.backup,
                  backup.deletingLastPathComponent().standardizedFileURL == parent,
                  backup.lastPathComponent == ".explorer-replace-\(entry.id.uuidString)" else {
                throw FileOperationError.underlying("The replacement record has an invalid backup path.")
            }
        case nil:
            throw FileOperationError.underlying("The recovery record has no transaction kind.")
        }
    }

    private func recoverReplacement(_ entry: Entry) throws -> (restored: [URL], finalized: [URL]) {
        guard let backup = entry.backup else {
            throw FileOperationError.underlying("The replacement recovery record has no backup path.")
        }
        switch entry.phase {
        case .prepared:
            if fileManager.fileExists(atPath: backup.path) {
                guard !fileManager.fileExists(atPath: entry.destination.path) else {
                    throw FileOperationError.underlying(
                        "Both a destination and an unverifiable replacement backup exist; neither was changed."
                    )
                }
                try restore(destination: entry.destination, backup: backup)
                return ([entry.destination], [])
            }
            guard fileManager.fileExists(atPath: entry.destination.path) else {
                throw FileOperationError.underlying(
                    "Both the original destination and its recovery backup are missing."
                )
            }
            return ([], [])
        case .backupCreated:
            guard fileManager.fileExists(atPath: backup.path) else {
                throw FileOperationError.underlying("The recovery backup is missing.")
            }
            guard !fileManager.fileExists(atPath: entry.destination.path) else {
                throw FileOperationError.underlying(
                    "Both a destination and an unverifiable replacement backup exist; neither was changed."
                )
            }
            try restore(destination: entry.destination, backup: backup)
            return ([entry.destination], [])
        case .replacementCompleted:
            if fileManager.fileExists(atPath: entry.destination.path) {
                if fileManager.fileExists(atPath: backup.path) {
                    throw FileOperationError.underlying(
                        "A completed destination and unverifiable legacy backup both exist; the backup was preserved."
                    )
                }
                return ([], [entry.destination])
            }
            if fileManager.fileExists(atPath: backup.path) {
                try restore(destination: entry.destination, backup: backup)
                return ([entry.destination], [])
            }
            throw FileOperationError.underlying(
                "Both the completed replacement and its recovery backup are missing."
            )
        case .rollbackCompleted:
            guard fileManager.fileExists(atPath: entry.destination.path) else {
                throw FileOperationError.underlying("The restored destination is missing.")
            }
            return ([], [])
        case .stagedCopyCompleted, .destinationCommitted, .sourceDeletionPrepared, .sourceRemoved,
             .sourceMovePrepared:
            throw FileOperationError.underlying(
                "The replacement recovery record contains an invalid phase."
            )
        }
    }

    private func recoverReplacementMove(
        _ entry: Entry
    ) throws -> (restored: [URL], finalized: [URL]) {
        guard let source = entry.source,
              let backup = entry.backup,
              let sourceFingerprint = entry.sourceFingerprint,
              let originalFingerprint = entry.originalDestinationFingerprint else {
            throw FileOperationError.underlying("The replacement move recovery record is incomplete.")
        }
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destinationExists = fileManager.fileExists(atPath: entry.destination.path)
        let backupExists = fileManager.fileExists(atPath: backup.path)

        switch entry.phase {
        case .prepared, .backupCreated:
            guard sourceExists else {
                throw FileOperationError.underlying(
                    "The move source disappeared before its commit was recorded."
                )
            }
            try requireFingerprint(
                sourceFingerprint,
                matches: source,
                failure: "The move source changed before recovery; no item was removed."
            )
            if backupExists {
                try requireFingerprint(
                    originalFingerprint,
                    matches: backup,
                    failure: "The replacement backup changed and was preserved."
                )
                guard !destinationExists else {
                    throw FileOperationError.underlying(
                        "The destination changed while the replacement move was interrupted."
                    )
                }
                try coordinatedMove(
                    from: backup,
                    to: entry.destination,
                    onlyIfMatches: originalFingerprint
                )
                return ([entry.destination], [])
            }
            guard destinationExists else {
                throw FileOperationError.underlying(
                    "Both the original destination and its recovery backup are missing."
                )
            }
            try requireFingerprint(
                originalFingerprint,
                matches: entry.destination,
                failure: "The original destination changed while the replacement move was interrupted."
            )
            return ([], [])
        case .sourceMovePrepared, .replacementCompleted:
            if !sourceExists, destinationExists {
                try requireFingerprint(
                    sourceFingerprint,
                    matches: entry.destination,
                    failure: "The committed destination does not match the original move source."
                )
                if backupExists {
                    try requireFingerprint(
                        originalFingerprint,
                        matches: backup,
                        failure: "The replacement backup changed and was preserved."
                    )
                    try coordinatedRemove(backup, onlyIfMatches: originalFingerprint)
                }
                return ([], [entry.destination])
            }
            if sourceExists, !destinationExists, backupExists {
                try requireFingerprint(
                    sourceFingerprint,
                    matches: source,
                    failure: "The move source changed before recovery; no item was removed."
                )
                try requireFingerprint(
                    originalFingerprint,
                    matches: backup,
                    failure: "The replacement backup changed and was preserved."
                )
                try coordinatedMove(
                    from: backup,
                    to: entry.destination,
                    onlyIfMatches: originalFingerprint
                )
                return ([entry.destination], [])
            }
            throw FileOperationError.underlying(
                "The interrupted replacement move has an ambiguous filesystem state."
            )
        case .rollbackCompleted:
            guard sourceExists, destinationExists else {
                throw FileOperationError.underlying("The replacement move rollback is incomplete.")
            }
            return ([], [])
        case .stagedCopyCompleted, .destinationCommitted, .sourceDeletionPrepared, .sourceRemoved:
            throw FileOperationError.underlying(
                "The replacement move recovery record contains an invalid phase."
            )
        }
    }

    private func discardIncompleteTransfer(_ entry: Entry) throws {
        guard let staging = entry.staging else {
            throw FileOperationError.underlying("The transfer recovery record has no staging path.")
        }
        if fileManager.fileExists(atPath: staging.path) {
            try coordinatedRemove(staging)
        }
        guard let backup = entry.backup else { return }
        guard fileManager.fileExists(atPath: backup.path) else {
            try requireFingerprint(
                entry.originalDestinationFingerprint,
                matches: entry.destination,
                failure: "The original destination changed while an interrupted transfer was being rolled back."
            )
            return
        }
        try requireFingerprint(
            entry.originalDestinationFingerprint,
            matches: backup,
            failure: "The replacement backup no longer matches the original destination."
        )
        guard !fileManager.fileExists(atPath: entry.destination.path) else {
            throw FileOperationError.underlying(
                "The destination changed while an interrupted transfer was being rolled back."
            )
        }
        try coordinatedMove(
            from: backup,
            to: entry.destination,
            onlyIfMatches: entry.originalDestinationFingerprint
        )
    }

    private func completeTransfer(_ entry: Entry) throws {
        guard let staging = entry.staging else {
            throw FileOperationError.underlying("The transfer recovery record has no staging path.")
        }
        let stagingExists = fileManager.fileExists(atPath: staging.path)
        let destinationExists = fileManager.fileExists(atPath: entry.destination.path)
        if stagingExists {
            try requireFingerprint(
                entry.stagingFingerprint,
                matches: staging,
                failure: "The staging item changed after the copy completed."
            )
            guard !destinationExists else {
                throw FileOperationError.underlying(
                    "Both the completed staging item and destination exist; neither was changed."
                )
            }
            try coordinatedMove(
                from: staging,
                to: entry.destination,
                onlyIfMatches: entry.stagingFingerprint
            )
        } else if !destinationExists {
            throw FileOperationError.underlying(
                "Both the completed staging item and destination are missing."
            )
        } else {
            try requireFingerprint(
                entry.stagingFingerprint,
                matches: entry.destination,
                failure: "The destination does not match the completed staging item."
            )
        }

        if entry.phase == .stagedCopyCompleted {
            try update(entry.id, phase: .destinationCommitted)
        }

        if entry.kind == .stagedMove, let source = entry.source,
           fileManager.fileExists(atPath: source.path) {
            guard let expectedSource = entry.sourceFingerprint else {
                throw FileOperationError.underlying(
                    "The interrupted move has no source identity record; the source was preserved."
                )
            }
            try requireFingerprint(
                expectedSource,
                matches: source,
                failure: "The move source changed after it was copied; the source was preserved."
            )
            if entry.phase != .sourceDeletionPrepared {
                try update(entry.id, phase: .sourceDeletionPrepared)
            }
            try coordinatedRemove(source, onlyIfMatches: expectedSource)
            try update(entry.id, phase: .sourceRemoved)
        }
        if let backup = entry.backup, fileManager.fileExists(atPath: backup.path) {
            try requireFingerprint(
                entry.originalDestinationFingerprint,
                matches: backup,
                failure: "The replacement backup changed and was preserved."
            )
            try coordinatedRemove(backup, onlyIfMatches: entry.originalDestinationFingerprint)
        }
    }

    private func requireFingerprint(
        _ expected: FileOperationFingerprint?,
        matches url: URL,
        failure: String
    ) throws {
        guard fingerprint(expected, matches: url) else {
            throw FileOperationError.underlying(failure)
        }
    }

    private func fingerprint(_ expected: FileOperationFingerprint?, matches url: URL) -> Bool {
        guard let expected, fileManager.fileExists(atPath: url.path) else { return false }
        return (try? FileOperationFingerprint.capture(at: url, fileManager: fileManager)) == expected
    }

    private func restore(destination: URL, backup: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileOperationError.underlying(
                "Recovery refused to overwrite an existing destination."
            )
        }
        try coordinatedMove(from: backup, to: destination)
    }

    private func coordinatedMove(from source: URL, to destination: URL) throws {
        try coordinator.coordinateMoving(from: source, to: destination) { coordinatedSource, coordinatedDestination in
            try fileManager.moveItem(at: coordinatedSource, to: coordinatedDestination)
        }
    }

    private func coordinatedMove(
        from source: URL,
        to destination: URL,
        onlyIfMatches expected: FileOperationFingerprint?
    ) throws {
        try coordinator.coordinateMoving(from: source, to: destination) { coordinatedSource, coordinatedDestination in
            guard let expected,
                  try FileOperationFingerprint.capture(
                    at: coordinatedSource,
                    fileManager: fileManager
                  ) == expected else {
                throw FileOperationError.underlying(
                    "The recovery item changed before it could be moved."
                )
            }
            try fileManager.moveItem(at: coordinatedSource, to: coordinatedDestination)
        }
    }

    private func coordinatedRemove(_ url: URL) throws {
        try coordinator.coordinateWriting(at: url, intent: .delete) { coordinatedURL in
            try fileManager.removeItem(at: coordinatedURL)
        }
    }


    private func coordinatedRemove(
        _ url: URL,
        onlyIfMatches expected: FileOperationFingerprint?
    ) throws {
        try coordinator.coordinateWriting(at: url, intent: .delete) { coordinatedURL in
            guard let expected,
                  try FileOperationFingerprint.capture(
                    at: coordinatedURL,
                    fileManager: fileManager
                  ) == expected else {
                throw FileOperationError.underlying(
                    "The recovery item changed before it could be removed."
                )
            }
            try fileManager.removeItem(at: coordinatedURL)
        }
    }
}
