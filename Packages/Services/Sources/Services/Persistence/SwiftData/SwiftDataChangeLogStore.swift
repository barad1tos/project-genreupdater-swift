// SwiftDataChangeLogStore.swift — SwiftData-backed change log persistence
// Phase 5 Audit Fix: H1 — UndoCoordinator persistence

import Core
import Foundation
import OSLog
import SwiftData

/// Persistent store for change log entries using SwiftData.
///
/// Uses `@ModelActor` for background-safe ModelContext access.
/// Enables `UndoCoordinator` to survive app restarts by persisting
/// every change entry to SwiftData.
@ModelActor
public actor SwiftDataChangeLogStore: ChangeLogStore {
    private let log = Logger(subsystem: "com.genreupdater", category: "ChangeLogStore")

    // MARK: - Save

    public func saveEntry(_ entry: Core.ChangeLogEntry) async throws {
        let persisted = PersistedChangeLogEntry(from: entry)
        linkToTrack(persisted)
        modelContext.insert(persisted)
        try modelContext.save()
        log.debug("Saved change log entry \(entry.id, privacy: .private)")
    }

    public func saveEntries(_ entries: [Core.ChangeLogEntry]) async throws {
        for entry in entries {
            let persisted = PersistedChangeLogEntry(from: entry)
            linkToTrack(persisted)
            modelContext.insert(persisted)
        }
        try modelContext.save()
        log.info("Saved \(entries.count, privacy: .public) change log entries")
    }

    // MARK: - Load

    public func loadAll() async throws -> [Core.ChangeLogEntry] {
        let descriptor = FetchDescriptor<PersistedChangeLogEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let persisted = try modelContext.fetch(descriptor)
        return persisted.map { $0.toChangeLogEntry() }
    }

    // MARK: - Delete

    public func delete(entryID: UUID) async throws {
        let descriptor = FetchDescriptor<PersistedChangeLogEntry>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            modelContext.delete(existing)
            try modelContext.save()
        }
    }

    public func deleteAll() async throws {
        let descriptor = FetchDescriptor<PersistedChangeLogEntry>()
        let all = try modelContext.fetch(descriptor)
        for entry in all {
            modelContext.delete(entry)
        }
        try modelContext.save()
        log.info("Cleared all change log entries")
    }

    // MARK: - Relationship Linking (H3)

    private func linkToTrack(_ persisted: PersistedChangeLogEntry) {
        let trackID = persisted.trackID
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate { $0.trackID == trackID }
        )
        if let track = try? modelContext.fetch(descriptor).first {
            persisted.track = track
        }
    }
}
