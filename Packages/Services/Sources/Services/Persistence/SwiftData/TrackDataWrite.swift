import Core
import Foundation
import SwiftData

extension TrackDataStore {
    @discardableResult
    public func commitAppliedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        try commitChange(change, history: .record)
    }

    @discardableResult
    public func commitObservedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        try commitChange(change, history: .ignore)
    }

    @discardableResult
    public func commitRevertedChange(
        _ change: ChangeLogEntry,
        removingHistoryEntryID entryID: UUID
    ) async throws -> MirrorRevision {
        try commitChange(change, history: .remove(entryID))
    }

    private enum HistoryChange {
        case record
        case remove(UUID)
        case ignore
    }

    private func commitChange(
        _ change: ChangeLogEntry,
        history historyChange: HistoryChange
    ) throws -> MirrorRevision {
        var committedRevision = MirrorRevision.initial
        do {
            try modelContext.transaction {
                let mirrorState = try mirrorStateForWrite()
                let baselineRevision = mirrorState.revision
                committedRevision = baselineRevision
                let storedHistory = try historyEntry(for: change, history: historyChange)
                try validateHistory(storedHistory, against: change, history: historyChange)
                let persistedTrack = try fetchTrack(id: change.trackID)
                let currentTrack = persistedTrack.toTrack()
                let updatedTrack = try currentTrack.applying(change)
                let hasAppliedState = Self.hasAppliedState(
                    change,
                    current: currentTrack,
                    updated: updatedTrack,
                    persisted: persistedTrack
                )
                let hasObservedMirrorState = try hasObservedMirrorState(
                    change,
                    updated: updatedTrack,
                    persisted: persistedTrack
                )
                guard !isRepeatedCommit(
                    history: historyChange,
                    storedHistory: storedHistory,
                    hasAppliedState: hasAppliedState,
                    hasObservedMirrorState: hasObservedMirrorState
                ) else {
                    applyHistory(historyChange, entry: change, stored: storedHistory, track: persistedTrack)
                    return
                }

                try updateTrack(persistedTrack, with: updatedTrack, change: change, history: historyChange)
                let nextRevision = try mirrorState.revision.advanced()
                try updateMember(for: change, track: updatedTrack, revision: nextRevision)
                applyHistory(historyChange, entry: change, stored: storedHistory, track: persistedTrack)
                committedRevision = try mirrorState.advanceRevision()
                let effects = MirrorEffect.forTrackTransition(from: currentTrack, to: updatedTrack)
                _ = try stageMirrorEffects(
                    effects,
                    revision: committedRevision,
                    baseline: baselineRevision
                )
            }
        } catch {
            modelContext.rollback()
            throw error
        }
        return committedRevision
    }

    private func mirrorStateForWrite() throws -> PersistedMirrorState {
        if let mirrorState = try fetchMirrorState() {
            return mirrorState
        }
        let mirrorState = PersistedMirrorState()
        modelContext.insert(mirrorState)
        return mirrorState
    }

    private func historyEntry(
        for entry: ChangeLogEntry,
        history historyChange: HistoryChange
    ) throws -> PersistedChangeLogEntry? {
        let entryID: UUID? = switch historyChange {
        case .record:
            entry.id
        case let .remove(existingID):
            existingID
        case .ignore:
            nil
        }
        guard let entryID else { return nil }
        let descriptor = FetchDescriptor<PersistedChangeLogEntry>(
            predicate: #Predicate { $0.entryID == entryID }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchTrack(id: String) throws -> PersistedTrack {
        let descriptor = FetchDescriptor<PersistedTrack>(
            predicate: #Predicate { $0.trackID == id }
        )
        guard let persistedTrack = try modelContext.fetch(descriptor).first else {
            throw TrackStoreError.missingTrack(id: id)
        }
        return persistedTrack
    }

    private func validateHistory(
        _ storedHistory: PersistedChangeLogEntry?,
        against entry: ChangeLogEntry,
        history historyChange: HistoryChange
    ) throws {
        guard case .record = historyChange, let storedHistory else { return }
        let recordedEntry = storedHistory.toChangeLogEntry()
        if Self.isCanonicalRepair(recordedEntry, entry) {
            storedHistory.update(from: entry)
        } else if !Self.hasSameEffect(recordedEntry, entry) {
            throw TrackStoreError.appliedChangeIdentityConflict(id: entry.id)
        }
    }

    private func isRepeatedCommit(
        history: HistoryChange,
        storedHistory: PersistedChangeLogEntry?,
        hasAppliedState: Bool,
        hasObservedMirrorState: Bool
    ) -> Bool {
        switch history {
        case .ignore:
            hasObservedMirrorState
        case .record:
            storedHistory != nil
                && hasAppliedState
        case .remove:
            storedHistory == nil
                && hasAppliedState
        }
    }

    private func hasObservedMirrorState(
        _ change: ChangeLogEntry,
        updated: Track,
        persisted: PersistedTrack
    ) throws -> Bool {
        guard let databaseID = MusicDatabaseTrackID(rawValue: change.trackID),
              persisted.mirrorMatches(updated, databaseID: databaseID)
        else { return false }
        guard change.changeType == .artistRename else { return true }
        let descriptor = FetchDescriptor<PersistedLibraryMember>(
            predicate: #Predicate { $0.databaseID == change.trackID && $0.isPresent }
        )
        guard let member = try modelContext.fetch(descriptor).first else { return false }
        return member.artist == updated.artist && member.albumArtist == updated.albumArtist
    }

    private func updateTrack(
        _ persistedTrack: PersistedTrack,
        with updatedTrack: Track,
        change: ChangeLogEntry,
        history: HistoryChange
    ) throws {
        switch history {
        case .ignore:
            guard let databaseID = MusicDatabaseTrackID(rawValue: change.trackID) else {
                throw TrackStoreError.missingDatabaseID(trackID: change.trackID)
            }
            persistedTrack.updateMirror(from: updatedTrack, databaseID: databaseID)
        case .record, .remove:
            persistedTrack.update(from: updatedTrack)
            updateProcessingState(persistedTrack, change: change)
        }
    }

    private func updateProcessingState(_ persistedTrack: PersistedTrack, change: ChangeLogEntry) {
        switch change.changeType {
        case .genreUpdate:
            persistedTrack.genreUpdated = true
        case .yearUpdate, .yearRevert:
            persistedTrack.yearUpdated = true
        case .trackCleaning, .albumCleaning, .artistRename:
            break
        }
        persistedTrack.processedDate = change.timestamp
    }

    private func updateMember(
        for change: ChangeLogEntry,
        track: Track,
        revision: MirrorRevision
    ) throws {
        guard change.changeType == .artistRename,
              let databaseID = MusicDatabaseTrackID(rawValue: change.trackID)
        else { return }
        let descriptor = FetchDescriptor<PersistedLibraryMember>(
            predicate: #Predicate { $0.databaseID == change.trackID && $0.isPresent }
        )
        guard let member = try modelContext.fetch(descriptor).first else { return }
        member.apply(
            identity: MemberIdentity(
                databaseID: databaseID,
                artist: track.artist,
                albumArtist: track.albumArtist,
                observedAt: change.timestamp
            ),
            revision: revision
        )
    }

    private func applyHistory(
        _ historyChange: HistoryChange,
        entry: ChangeLogEntry,
        stored: PersistedChangeLogEntry?,
        track: PersistedTrack
    ) {
        switch historyChange {
        case .record:
            let historyEntry = stored ?? PersistedChangeLogEntry(from: entry)
            historyEntry.track = track
            if stored == nil {
                modelContext.insert(historyEntry)
            }
        case .remove:
            if let stored {
                modelContext.delete(stored)
            }
        case .ignore:
            break
        }
    }

    private static func hasSameEffect(_ lhs: ChangeLogEntry, _ rhs: ChangeLogEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.changeType == rhs.changeType
            && lhs.trackID == rhs.trackID
            && lhs.oldGenre == rhs.oldGenre
            && lhs.newGenre == rhs.newGenre
            && lhs.oldYear == rhs.oldYear
            && lhs.newYear == rhs.newYear
            && lhs.oldTrackName == rhs.oldTrackName
            && lhs.newTrackName == rhs.newTrackName
            && lhs.oldAlbumName == rhs.oldAlbumName
            && lhs.newAlbumName == rhs.newAlbumName
            && lhs.oldArtist == rhs.oldArtist
            && lhs.newArtist == rhs.newArtist
            && lhs.albumArtistChange == rhs.albumArtistChange
            && lhs.runID == rhs.runID
    }

    private static func isCanonicalRepair(_ lhs: ChangeLogEntry, _ rhs: ChangeLogEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.trackID != rhs.trackID
            && MusicDatabaseTrackID(rawValue: rhs.trackID) != nil
            && lhs.runID != nil
            && lhs.runID == rhs.runID
            && lhs.changeType == rhs.changeType
            && lhs.oldGenre == rhs.oldGenre
            && lhs.newGenre == rhs.newGenre
            && lhs.oldYear == rhs.oldYear
            && lhs.newYear == rhs.newYear
            && lhs.oldTrackName == rhs.oldTrackName
            && lhs.newTrackName == rhs.newTrackName
            && lhs.oldAlbumName == rhs.oldAlbumName
            && lhs.newAlbumName == rhs.newAlbumName
            && lhs.oldArtist == rhs.oldArtist
            && lhs.newArtist == rhs.newArtist
            && lhs.albumArtistChange == rhs.albumArtistChange
    }

    private static func hasAppliedState(
        _ change: ChangeLogEntry,
        current: Track,
        updated: Track,
        persisted: PersistedTrack
    ) -> Bool {
        guard current == updated, persisted.processedDate != nil else { return false }
        return switch change.changeType {
        case .genreUpdate:
            persisted.genreUpdated
        case .yearUpdate, .yearRevert:
            persisted.yearUpdated
        case .trackCleaning, .albumCleaning, .artistRename:
            true
        }
    }
}
