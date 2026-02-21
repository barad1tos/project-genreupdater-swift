import Core
import Foundation
import OSLog

// MARK: - Batch Checkpoint

/// Snapshot of batch processing progress, persisted to JSON.
public struct BatchCheckpoint: Sendable, Codable, Equatable {
    public let batchID: UUID
    public let processedTrackIDs: [String]
    public let totalCount: Int
    public let lastProcessedIndex: Int
    public let timestamp: Date
    public let changes: [ChangeLogEntry]

    public init(
        batchID: UUID,
        processedTrackIDs: [String],
        totalCount: Int,
        lastProcessedIndex: Int,
        timestamp: Date = Date(),
        changes: [ChangeLogEntry] = []
    ) {
        self.batchID = batchID
        self.processedTrackIDs = processedTrackIDs
        self.totalCount = totalCount
        self.lastProcessedIndex = lastProcessedIndex
        self.timestamp = timestamp
        self.changes = changes
    }
}

// MARK: - Checkpoint Manager

/// Saves and restores batch progress to JSON files in Application Support.
///
/// Storage layout: `{directory}/checkpoints/{batchID}.json`
/// Cleanup: deletes checkpoints older than 7 days by default.
public actor CheckpointManager {
    private let directory: URL
    private let fileManager: FileManager
    private let log = Logger(subsystem: "com.genreupdater", category: "CheckpointManager")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        self.directory = base.appendingPathComponent("checkpoints", isDirectory: true)
        self.fileManager = .default
    }

    // MARK: Save

    public func save(_ checkpoint: BatchCheckpoint) async throws {
        try ensureDirectoryExists()
        let url = fileURL(for: checkpoint.batchID)
        let data = try encoder.encode(checkpoint)
        try data.write(to: url, options: .atomic)
        log
            .info(
                "Saved checkpoint \(checkpoint.batchID, privacy: .public) at index \(checkpoint.lastProcessedIndex, privacy: .public)/\(checkpoint.totalCount, privacy: .public)"
            )
    }

    // MARK: Load

    public func load(batchID: UUID) async throws -> BatchCheckpoint? {
        let url = fileURL(for: batchID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(BatchCheckpoint.self, from: data)
        } catch {
            log
                .warning(
                    "Corrupt checkpoint \(batchID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            return nil
        }
    }

    /// Load the most recent checkpoint across all batches.
    public func loadLatest() async throws -> BatchCheckpoint? {
        try ensureDirectoryExists()
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var latest: BatchCheckpoint?
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let checkpoint = try decoder.decode(BatchCheckpoint.self, from: data)
                if checkpoint.timestamp > (latest?.timestamp ?? .distantPast) {
                    latest = checkpoint
                }
            } catch {
                log.warning("Skipping corrupt checkpoint at \(file.lastPathComponent, privacy: .public)")
                continue
            }
        }
        return latest
    }

    // MARK: Delete

    public func delete(batchID: UUID) async throws {
        let url = fileURL(for: batchID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        log.info("Deleted checkpoint \(batchID, privacy: .public)")
    }

    /// Remove checkpoints older than the given interval (default 7 days).
    public func cleanupOld(olderThan: TimeInterval = 7 * 24 * 3600) async throws {
        try ensureDirectoryExists()
        let cutoff = Date().addingTimeInterval(-olderThan)
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var removedCount = 0
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let checkpoint = try decoder.decode(BatchCheckpoint.self, from: data)
                if checkpoint.timestamp < cutoff {
                    try fileManager.removeItem(at: file)
                    removedCount += 1
                }
            } catch {
                log.warning("Removing corrupt checkpoint: \(file.lastPathComponent, privacy: .public)")
                try? fileManager.removeItem(at: file)
                removedCount += 1
            }
        }
        if removedCount > 0 {
            log.info("Cleaned up \(removedCount, privacy: .public) old checkpoint(s)")
        }
    }

    // MARK: Helpers

    private func fileURL(for batchID: UUID) -> URL {
        directory.appendingPathComponent("\(batchID.uuidString).json")
    }

    private func ensureDirectoryExists() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func defaultDirectory() -> URL {
        let directories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        guard let appSupport = directories.first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
        }
        return appSupport.appendingPathComponent("GenreUpdater", isDirectory: true)
    }
}
