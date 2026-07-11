import Core
import Foundation
import Services

enum ReportsWriteError: LocalizedError {
    case servicesUnavailable

    var errorDescription: String? {
        "Report write services are unavailable"
    }
}

struct ReportsWrite {
    let batchProcessor: BatchProcessor
    let undoCoordinator: UndoCoordinator

    func undo(_ entry: ChangeLogEntry, hasRunRecovery: Bool) async throws {
        try await perform(hasRunRecovery: hasRunRecovery) {
            try await undoCoordinator.revertChange(entry)
        }
    }

    func undoSession(_ entries: [ChangeLogEntry], hasRunRecovery: Bool) async throws {
        try await perform(hasRunRecovery: hasRunRecovery) {
            try await undoCoordinator.revertBatch(entries)
        }
    }

    func restoreYears(
        csv: String,
        artist: String,
        album: String?,
        tracks: [Track],
        hasRunRecovery: Bool
    ) async throws -> YearBackupRevertResult {
        try await perform(hasRunRecovery: hasRunRecovery) {
            try await undoCoordinator.revertYearsFromBackupCSV(
                csv,
                artist: artist,
                album: album,
                currentTracks: tracks
            )
        }
    }

    private func perform<Value: Sendable>(
        hasRunRecovery: Bool,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await batchProcessor.performRecoverableWrite {
            guard !hasRunRecovery else {
                throw WriteAdmissionError.recoveryRequired
            }
            return try await operation()
        }
    }
}

extension AppDependencies {
    func makeReportsWrite() throws -> ReportsWrite {
        guard let batchProcessor, let undoCoordinator else {
            throw ReportsWriteError.servicesUnavailable
        }
        return ReportsWrite(batchProcessor: batchProcessor, undoCoordinator: undoCoordinator)
    }
}
