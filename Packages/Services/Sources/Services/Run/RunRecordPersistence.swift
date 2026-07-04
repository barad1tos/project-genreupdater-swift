import Foundation
import OSLog

/// Builds the orchestrator's persist sink over a run record store.
public enum RunRecordPersistence {
    private static let log = Logger(subsystem: "com.genreupdater", category: "RunRecordPersistence")

    /// Upserts every record and, after terminal records, prunes history to the
    /// current limit. Prune failures are logged and never fail the persist:
    /// the record is already written; retention is housekeeping. A nil limit
    /// (torn-down provider) skips pruning — deletion never runs on a guessed
    /// default below the user's configured value.
    public static func makePersistSink(
        store: any RunRecordStore,
        historyLimit: @escaping @Sendable () async -> Int?
    ) -> @Sendable (RunRecord) async throws -> Void {
        { record in
            try await store.upsert(record)
            guard record.finishedAt != nil else { return }
            guard let limit = await historyLimit() else { return }

            do {
                _ = try await store.prune(keepingLatest: limit)
            } catch {
                log.error("""
                Run history pruning failed with \
                \(String(describing: type(of: error)), privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """)
            }
        }
    }
}
