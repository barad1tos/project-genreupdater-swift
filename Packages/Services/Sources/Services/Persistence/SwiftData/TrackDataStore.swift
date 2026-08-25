// Phase 2A: Persistence Layer

import Core
import Foundation
import OSLog
import SwiftData

/// Persistent store for track processing state using SwiftData.
///
/// Uses `@ModelActor` for background-safe ModelContext access.
/// Designed for libraries with 30K+ tracks — batch operations use
/// chunked inserts to avoid memory pressure.
@ModelActor
public actor TrackDataStore: TrackStateStore {
    private let log = AppLogger.make(category: "trackstore")

    // MARK: - Initialization

    public func initialize() async throws {
        let repairedCount = try normalizeStoredYears()
        let isMirrorSeeded = try initializeMirrorState()
        log.info("SwiftData track store initialized; repaired zero-year rows: \(repairedCount, privacy: .public)")
        log.info("SwiftData track mirror initialized; seeded: \(isMirrorSeeded, privacy: .public)")
    }

    // MARK: - Read Operations

    public func loadAllTracks() async throws -> [Track] {
        try fetchAllTracks()
    }

    public func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        let tracks = try fetchAllTracks()
        let state = try fetchMirrorState()
        return TrackMirrorSnapshot(
            tracks: tracks,
            isSeeded: state?.isSeeded ?? false
        )
    }

    private func fetchAllTracks() throws -> [Track] {
        let descriptor = FetchDescriptor<PersistedTrack>(
            sortBy: [SortDescriptor(\.name)]
        )
        let persisted = try modelContext.fetch(descriptor)
        return persisted.map { $0.toTrack() }
    }

    public func getTrack(byID id: String) async throws -> Track? {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate { $0.trackID == id }
        )
        return try modelContext.fetch(descriptor).first?.toTrack()
    }

    public func getUnprocessedTracks() async throws -> [Track] {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate {
                $0.genreUpdated == false || $0.yearUpdated == false
            }
        )
        let persisted = try modelContext.fetch(descriptor)
        return persisted.map { $0.toTrack() }
    }

    public func trackCount() async throws -> Int {
        let descriptor = FetchDescriptor<PersistedTrack>()
        return try modelContext.fetchCount(descriptor)
    }

    // MARK: - Write Operations

    public func applyMirror(_ update: TrackMirrorUpdate) async throws {
        let plan = try Self.validate(update)
        let currentTracks = try modelContext.fetch(FetchDescriptor<PersistedTrack>())
        try Self.validateStored(plan, tracks: currentTracks)

        var deletedCount = 0
        do {
            try modelContext.transaction {
                let transactionPlan = try Self.validate(update)
                let storedTracks = try modelContext.fetch(FetchDescriptor<PersistedTrack>())
                let storedState = try Self.validateStored(transactionPlan, tracks: storedTracks)
                let history = try modelContext.fetch(FetchDescriptor<PersistedChangeLogEntry>())

                for repair in transactionPlan.repairs {
                    try Self.applyRepair(repair, state: storedState, history: history, modelContext: modelContext)
                }

                for (track, databaseID) in zip(update.upserts, transactionPlan.upsertIDs) {
                    if let persistedTrack = storedState.canonicalByID[databaseID] {
                        persistedTrack.updateMirror(from: track, databaseID: databaseID)
                    } else {
                        modelContext.insert(PersistedTrack(mirror: track, databaseID: databaseID))
                    }
                }

                for id in transactionPlan.deletions {
                    guard let persistedTrack = storedState.canonicalByID[id] else { continue }
                    modelContext.delete(persistedTrack)
                    deletedCount += 1
                }

                if let mirrorState = try fetchMirrorState() {
                    mirrorState.isSeeded = true
                } else {
                    modelContext.insert(PersistedMirrorState(isSeeded: true))
                }
            }
        } catch {
            modelContext.rollback()
            throw error
        }

        log.info("Applied mirror repairs: \(update.repairs.count, privacy: .public)")
        log
            .info(
                "Applied mirror upserts: \(update.upserts.count, privacy: .public); deletions: \(deletedCount, privacy: .public)"
            )
    }

    public func persistAppliedChange(_ change: ChangeLogEntry) async throws {
        do {
            let descriptor = FetchDescriptor<PersistedTrack>(
                predicate: #Predicate { $0.trackID == change.trackID }
            )
            guard let persisted = try modelContext.fetch(descriptor).first else {
                throw TrackStoreError.missingTrack(id: change.trackID)
            }

            let updated = try persisted.toTrack().applying(change)
            persisted.update(from: updated)
            switch change.changeType {
            case .genreUpdate:
                persisted.genreUpdated = true
            case .yearUpdate, .yearRevert:
                persisted.yearUpdated = true
            case .trackCleaning, .albumCleaning, .artistRename:
                break
            }
            persisted.processedDate = .now

            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func normalizeStoredYears() throws -> Int {
        let missingValue = MusicAppYear.missingValue
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate {
                $0.year == missingValue || $0.releaseYear == missingValue
            }
        )
        let tracks = try modelContext.fetch(descriptor)
        guard !tracks.isEmpty else { return 0 }

        do {
            for track in tracks {
                track.year = MusicAppYear.normalized(track.year)
                track.releaseYear = MusicAppYear.normalized(track.releaseYear)
            }
            try modelContext.save()
            return tracks.count
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func initializeMirrorState() throws -> Bool {
        if let state = try fetchMirrorState() {
            return state.isSeeded
        }

        let isSeeded = try modelContext.fetchCount(FetchDescriptor<PersistedTrack>()) > 0
        modelContext.insert(PersistedMirrorState(isSeeded: isSeeded))
        try modelContext.save()
        return isSeeded
    }

    private func fetchMirrorState() throws -> PersistedMirrorState? {
        let key = PersistedMirrorState.primaryKey
        let descriptor = FetchDescriptor<PersistedMirrorState>(
            predicate: #Predicate { $0.key == key }
        )
        return try modelContext.fetch(descriptor).first
    }

    private static func duplicateIDs(in ids: [MusicDatabaseTrackID]) -> [MusicDatabaseTrackID] {
        var seen = Set<MusicDatabaseTrackID>()
        var duplicates = Set<MusicDatabaseTrackID>()
        for id in ids where !seen.insert(id).inserted {
            duplicates.insert(id)
        }
        return duplicates.sorted { $0.rawValue < $1.rawValue }
    }

    private static func canonicalIDs(for tracks: [Track]) throws -> [MusicDatabaseTrackID] {
        try tracks.map { track in
            guard let databaseID = track.databaseID else {
                throw TrackStoreError.missingDatabaseID(trackID: track.id)
            }
            guard track.id == databaseID.rawValue else {
                throw TrackStoreError.nonCanonicalTrack(trackID: track.id, databaseID: databaseID)
            }
            return databaseID
        }
    }

    private struct ValidatedRepair {
        let sourceID: String
        let targetID: MusicDatabaseTrackID
        let track: Track
    }

    private struct MirrorPlan {
        let repairs: [ValidatedRepair]
        let upsertIDs: [MusicDatabaseTrackID]
        let deletions: [MusicDatabaseTrackID]
    }

    private struct StoredMirrorState {
        let byID: [String: PersistedTrack]
        let canonicalByID: [MusicDatabaseTrackID: PersistedTrack]
    }

    private static func validate(_ update: TrackMirrorUpdate) throws -> MirrorPlan {
        let repairs = try validatedRepairs(update.repairs)
        let upsertIDs = try canonicalIDs(for: update.upserts)
        let duplicateUpserts = duplicateIDs(in: upsertIDs)
        guard duplicateUpserts.isEmpty else {
            throw TrackStoreError.duplicateUpserts(ids: duplicateUpserts)
        }

        let duplicateDeletions = duplicateIDs(in: update.deletions)
        guard duplicateDeletions.isEmpty else {
            throw TrackStoreError.duplicateDeletions(ids: duplicateDeletions)
        }

        let sortedDeletions = update.deletions.sorted { $0.rawValue < $1.rawValue }
        let overlappingIDs = overlapIDs(repairs: repairs, upserts: upsertIDs, deletions: sortedDeletions)
        guard overlappingIDs.isEmpty else {
            throw TrackStoreError.identityOverlap(ids: overlappingIDs)
        }
        return MirrorPlan(repairs: repairs, upsertIDs: upsertIDs, deletions: sortedDeletions)
    }

    private static func validatedRepairs(_ repairs: [TrackMirrorRepair]) throws -> [ValidatedRepair] {
        let emptySource = repairs.contains { $0.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !emptySource else { throw TrackStoreError.emptySource }

        let duplicateSources = duplicateStrings(in: repairs.map(\.sourceID))
        guard duplicateSources.isEmpty else {
            throw TrackStoreError.duplicateRepairSources(ids: duplicateSources)
        }

        let targetIDs = try canonicalIDs(for: repairs.map(\.target))
        let duplicateTargets = duplicateIDs(in: targetIDs)
        guard duplicateTargets.isEmpty else {
            throw TrackStoreError.duplicateRepairTargets(ids: duplicateTargets)
        }

        return zip(repairs, targetIDs).map { repair, targetID in
            ValidatedRepair(sourceID: repair.sourceID, targetID: targetID, track: repair.target)
        }
    }

    private static func overlapIDs(
        repairs: [ValidatedRepair],
        upserts: [MusicDatabaseTrackID],
        deletions: [MusicDatabaseTrackID]
    ) -> [MusicDatabaseTrackID] {
        let targets = Set(repairs.map(\.targetID))
        let upsertSet = Set(upserts)
        let deletionSet = Set(deletions)
        let overlaps = targets.intersection(upsertSet)
            .union(targets.intersection(deletionSet))
            .union(upsertSet.intersection(deletionSet))
        return overlaps.sorted { $0.rawValue < $1.rawValue }
    }

    @discardableResult
    private static func validateStored(_ plan: MirrorPlan, tracks: [PersistedTrack]) throws -> StoredMirrorState {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackID, $0) })
        for repair in plan.repairs {
            let source = byID[repair.sourceID]
            let target = byID[repair.targetID.rawValue]
            guard source != nil || target?.isCanonical(databaseID: repair.targetID) == true else {
                throw TrackStoreError.missingSource(id: repair.sourceID)
            }
            if let source, repair.sourceID == repair.targetID.rawValue {
                guard source.appleScriptID != source.trackID else {
                    throw TrackStoreError.redundantRepair(id: repair.targetID)
                }
            } else if let target, !target.isCanonical(databaseID: repair.targetID) {
                throw TrackStoreError.targetExists(id: repair.targetID)
            }
        }

        let operationIDs = Set(plan.upsertIDs).union(plan.deletions)
        let canonicalByID = try indexCanonicalTracks(tracks, operationIDs: operationIDs)
        return StoredMirrorState(byID: byID, canonicalByID: canonicalByID)
    }

    private static func applyRepair(
        _ repair: ValidatedRepair,
        state: StoredMirrorState,
        history: [PersistedChangeLogEntry],
        modelContext: ModelContext
    ) throws {
        let source = state.byID[repair.sourceID]
        let target = state.canonicalByID[repair.targetID]
        let sourceHistory = history.filter { entry in
            entry.trackID == repair.sourceID || entry.track === source
        }
        let persistedTrack: PersistedTrack
        let sourceToDelete: PersistedTrack?
        if let source, let target, source !== target {
            target.mergeRepair(source, with: repair.track, databaseID: repair.targetID)
            persistedTrack = target
            sourceToDelete = source
        } else if let source {
            source.repairMirror(with: repair.track, databaseID: repair.targetID)
            persistedTrack = source
            sourceToDelete = nil
        } else if let target {
            target.updateMirror(from: repair.track, databaseID: repair.targetID)
            persistedTrack = target
            sourceToDelete = nil
        } else {
            throw TrackStoreError.missingSource(id: repair.sourceID)
        }
        for entry in sourceHistory {
            entry.trackID = repair.targetID.rawValue
            entry.track = persistedTrack
        }
        if let sourceToDelete {
            sourceToDelete.changeLog.removeAll()
            modelContext.delete(sourceToDelete)
        }
    }

    private static func indexCanonicalTracks(
        _ tracks: [PersistedTrack],
        operationIDs: Set<MusicDatabaseTrackID>
    ) throws -> [MusicDatabaseTrackID: PersistedTrack] {
        var canonicalByID: [MusicDatabaseTrackID: PersistedTrack] = [:]
        var collisions = Set<MusicDatabaseTrackID>()
        for track in tracks {
            guard let databaseID = MusicDatabaseTrackID(rawValue: track.trackID) else { continue }
            guard track.appleScriptID == track.trackID else {
                if operationIDs.contains(databaseID) {
                    collisions.insert(databaseID)
                }
                continue
            }
            canonicalByID[databaseID] = track
        }
        guard collisions.isEmpty else {
            throw TrackStoreError.identityCollisions(ids: collisions.sorted { $0.rawValue < $1.rawValue })
        }
        return canonicalByID
    }

    private static func duplicateStrings(in values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates.sorted()
    }
}

// MARK: - Factory

extension TrackDataStore {
    /// Create a track store with the default shared ModelContainer.
    public static func createDefault() throws -> TrackDataStore {
        let container = try ModelContainerFactory.create()
        return TrackDataStore(modelContainer: container)
    }

    /// Create a track store with an in-memory container (for testing).
    public static func createInMemory() throws -> TrackDataStore {
        let container = try ModelContainerFactory.createInMemory()
        return TrackDataStore(modelContainer: container)
    }
}
