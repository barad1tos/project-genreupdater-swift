import Core
import Foundation

/// Rebuilds durable change-history evidence for writes that landed in
/// Music.app but lost their finalization (undo history or processed-track
/// persistence). Recovery clearance repairs the history from checkpointed
/// work items and observed outcomes, or keeps the hold when repair fails.
public enum RecoveryEvidenceRepair {
    /// The change-history entry a work item's landed write should have
    /// recorded, or nil when the item carries no write identity.
    public static func changeLogEntry(for item: RunWorkItem) -> ChangeLogEntry? {
        guard case let .track(identity) = item.target,
              let trackID = identity.appleScriptID,
              !trackID.isEmpty
        else { return nil }
        var entry = ChangeLogEntry(
            changeType: item.change.changeType,
            trackID: identity.readID,
            artist: identity.artist,
            trackName: identity.trackName,
            albumName: identity.album
        )
        switch item.change.changeType {
        case .genreUpdate:
            entry.oldGenre = item.change.oldValue
            entry.newGenre = item.change.newValue
        case .yearUpdate, .yearRevert:
            entry.oldYear = item.change.oldValue.flatMap(Int.init)
            entry.newYear = item.change.newValue.flatMap(Int.init)
        case .trackCleaning:
            entry.oldTrackName = item.change.oldValue
            entry.newTrackName = item.change.newValue
        case .albumCleaning:
            entry.oldAlbumName = item.change.oldValue
            entry.newAlbumName = item.change.newValue
        case .artistRename:
            entry.oldArtist = item.change.oldValue
            entry.newArtist = item.change.newValue
        }
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

    /// Returns missing canonical entries for written items. A same-run legacy
    /// AppleScript-ID entry is rewritten to the read ID while preserving its
    /// event identity; entries owned by another run are never rewritten.
    public static func missingEntries(
        for items: [RunWorkItem],
        existing: [ChangeLogEntry],
        runID: UUID
    ) -> [ChangeLogEntry] {
        items.compactMap { item -> ChangeLogEntry? in
            guard let candidate = changeLogEntry(for: item),
                  !existing.contains(where: { matches($0, candidate) })
            else { return nil }
            guard case let .track(identity) = item.target,
                  identity.appleScriptID != candidate.trackID,
                  let legacy = existing.first(where: {
                      $0.trackID == identity.appleScriptID
                          && $0.runID == runID
                          && matchesChange($0, candidate)
                  })
            else { return candidate }
            return canonicalEntry(candidate, preserving: legacy)
        }
    }

    private static func matches(_ recorded: ChangeLogEntry, _ candidate: ChangeLogEntry) -> Bool {
        recorded.trackID == candidate.trackID
            && matchesChange(recorded, candidate)
    }

    private static func matchesChange(_ recorded: ChangeLogEntry, _ candidate: ChangeLogEntry) -> Bool {
        recorded.changeType == candidate.changeType
            && recorded.newGenre == candidate.newGenre
            && recorded.newYear == candidate.newYear
            && recorded.newTrackName == candidate.newTrackName
            && recorded.newAlbumName == candidate.newAlbumName
            && recorded.newArtist == candidate.newArtist
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
            newArtist: candidate.newArtist
        )
        canonical.runID = legacy.runID
        return canonical
    }
}
