import Core
import Foundation

/// Rebuilds durable change-history evidence for writes that landed in
/// Music.app but lost their finalization (undo history or processed-track
/// persistence). Recovery clearance repairs the history from checkpointed
/// work items and observed outcomes, or keeps the hold when repair fails.
public enum RecoveryEvidenceRepair {
    /// The change-history entry a work item's landed write should have
    /// recorded, or nil when the item carries no write identity.
    public static func changeLogEntry(for item: RunWorkItem, runID: UUID) -> ChangeLogEntry? {
        guard case let .track(identity) = item.target,
              let rawDatabaseID = identity.appleScriptID,
              let databaseID = MusicDatabaseTrackID(rawValue: rawDatabaseID)
        else { return nil }
        let change = item.effectiveChange
        var entry = ChangeLogEntry(
            id: RunChangeID.make(runID: runID, itemID: item.id),
            timestamp: .now,
            changeType: change.changeType,
            trackID: databaseID.rawValue,
            artist: identity.artist,
            trackName: identity.trackName,
            albumName: identity.album
        )
        switch change.changeType {
        case .genreUpdate:
            entry.oldGenre = change.oldValue
            entry.newGenre = change.newValue
        case .yearUpdate, .yearRevert:
            entry.oldYear = change.oldValue.flatMap(Int.init)
            entry.newYear = change.newValue.flatMap(Int.init)
        case .trackCleaning:
            entry.oldTrackName = change.oldValue
            entry.newTrackName = change.newValue
        case .albumCleaning:
            entry.oldAlbumName = change.oldValue
            entry.newAlbumName = change.newValue
        case .artistRename:
            entry.oldArtist = change.oldValue
            entry.newArtist = change.newValue
            entry.albumArtistChange = change.albumArtistChange
        }
        entry.runID = runID
        return entry
    }

    /// Items whose write provably landed: checkpointed terminal `.written`
    /// (finalization was lost after the durable checkpoint) plus open items
    /// the live observation classified `.written`.
    public static func writtenItems(
        in items: [RunWorkItem],
        observed: [UUID: ObservedWorkOutcome]?
    ) -> [RunWorkItem] {
        items.filter { item in
            if item.state == .outcome(.written) {
                return true
            }
            return observed?[item.id]?.outcome == .written
        }
    }

    /// Terminal no-op items whose observed Music.app values still need a
    /// durable mirror finalization, but must never create undo history. A user
    /// acknowledgement deliberately leaves the existing mirror untouched.
    public static func noOpItems(in items: [RunWorkItem]) -> [RunWorkItem] {
        items.filter {
            $0.state == .outcome(.noFixNeeded) && $0.dismissedAt == nil
        }
    }

    /// Returns one canonical durable event for every landed work item.
    /// Existing history keeps its event identity; missing history uses the
    /// deterministic run-scoped identity so retries and relaunches converge
    /// without colliding with a continuation of the same plan item.
    public static func finalizationEntries(
        for items: [RunWorkItem],
        existing: [ChangeLogEntry],
        runID: UUID
    ) -> [ChangeLogEntry] {
        items.compactMap { item in
            guard let candidate = changeLogEntry(for: item, runID: runID) else { return nil }
            if let recorded = existing.first(where: {
                matchesStoredEvent($0, candidate: candidate, runID: runID)
            }) {
                return recorded
            }
            guard case let .track(identity) = item.target,
                  identity.readID != candidate.trackID,
                  let legacy = existing.first(where: {
                      $0.trackID == identity.readID
                          && $0.runID == runID
                          && matchesChange($0, candidate)
                  })
            else { return candidate }
            return canonicalEntry(candidate, preserving: legacy)
        }
    }

    /// Returns one mirror-only finalization entry for every checkpointed no-op.
    /// Current payloads use their persisted write effect; legacy payloads must
    /// instead carry a fresh physical observation so a stale proposal can never
    /// overwrite the mirror during recovery. Throws an actionable observation
    /// issue instead of silently omitting an item that still needs attention.
    public static func noOpFinalizationEntries(
        for items: [RunWorkItem],
        observed: [UUID: ObservedWorkOutcome]?,
        runID: UUID
    ) throws -> [ChangeLogEntry] {
        try items.map { item in
            if item.writeChange != nil {
                guard let entry = changeLogEntry(for: item, runID: runID) else {
                    throw RecoveryObservationIssue.writeIdentityMissing
                }
                return entry
            }
            guard let outcome = observed?[item.id] else {
                throw RecoveryObservationIssue.observationUnavailable
            }
            if let issue = outcome.issue {
                throw issue
            }
            guard outcome.outcome == .noFixNeeded,
                  let effect = outcome.observedNoOpEffect
            else {
                throw RecoveryObservationIssue.observationUnavailable
            }
            guard let entry = observedNoOpEntry(for: item, effect: effect, runID: runID) else {
                throw RecoveryObservationIssue.writeIdentityMissing
            }
            return entry
        }
    }

    private static func matches(_ recorded: ChangeLogEntry, _ candidate: ChangeLogEntry) -> Bool {
        recorded.trackID == candidate.trackID
            && matchesChange(recorded, candidate)
    }

    private static func matchesStoredEvent(
        _ recorded: ChangeLogEntry,
        candidate: ChangeLogEntry,
        runID: UUID
    ) -> Bool {
        recorded.runID == runID && matches(recorded, candidate)
    }

    private static func matchesChange(_ recorded: ChangeLogEntry, _ candidate: ChangeLogEntry) -> Bool {
        recorded.changeType == candidate.changeType
            && recorded.oldGenre == candidate.oldGenre
            && recorded.newGenre == candidate.newGenre
            && recorded.oldYear == candidate.oldYear
            && recorded.newYear == candidate.newYear
            && recorded.oldTrackName == candidate.oldTrackName
            && recorded.newTrackName == candidate.newTrackName
            && recorded.oldAlbumName == candidate.oldAlbumName
            && recorded.newAlbumName == candidate.newAlbumName
            && recorded.oldArtist == candidate.oldArtist
            && recorded.newArtist == candidate.newArtist
            && recorded.albumArtistChange == candidate.albumArtistChange
    }

    private static func canonicalEntry(
        _ candidate: ChangeLogEntry,
        preserving legacy: ChangeLogEntry
    ) -> ChangeLogEntry {
        var canonical = ChangeLogEntry(
            id: legacy.id,
            timestamp: legacy.timestamp,
            changeType: candidate.changeType,
            trackID: candidate.trackID,
            artist: candidate.artist,
            trackName: candidate.trackName,
            albumName: candidate.albumName,
            oldGenre: candidate.oldGenre,
            newGenre: candidate.newGenre,
            oldYear: candidate.oldYear,
            newYear: candidate.newYear,
            oldTrackName: candidate.oldTrackName,
            newTrackName: candidate.newTrackName,
            oldAlbumName: candidate.oldAlbumName,
            newAlbumName: candidate.newAlbumName,
            oldArtist: candidate.oldArtist,
            newArtist: candidate.newArtist,
            albumArtistChange: candidate.albumArtistChange
        )
        canonical.runID = legacy.runID
        return canonical
    }

    private static func observedNoOpEntry(
        for item: RunWorkItem,
        effect: ObservedNoOpEffect,
        runID: UUID
    ) -> ChangeLogEntry? {
        guard case let .track(identity) = item.target,
              let rawDatabaseID = identity.appleScriptID,
              let databaseID = MusicDatabaseTrackID(rawValue: rawDatabaseID)
        else { return nil }
        var entry = ChangeLogEntry(
            id: RunChangeID.make(runID: runID, itemID: item.id),
            timestamp: .now,
            changeType: item.change.changeType,
            trackID: databaseID.rawValue,
            artist: identity.artist,
            trackName: identity.trackName,
            albumName: identity.album
        )
        switch item.change.changeType {
        case .genreUpdate:
            entry.oldGenre = effect.value
            entry.newGenre = effect.value
        case .yearUpdate, .yearRevert:
            entry.oldYear = Int(effect.value)
            entry.newYear = Int(effect.value)
        case .trackCleaning:
            entry.oldTrackName = effect.value
            entry.newTrackName = effect.value
        case .albumCleaning:
            entry.oldAlbumName = effect.value
            entry.newAlbumName = effect.value
        case .artistRename:
            entry.oldArtist = effect.value
            entry.newArtist = effect.value
            if let albumArtistValue = effect.albumArtistValue {
                entry.albumArtistChange = AlbumArtistChange(
                    oldValue: albumArtistValue,
                    newValue: albumArtistValue
                )
            }
        }
        entry.runID = runID
        return entry
    }
}
