import Foundation
import SwiftData

/// Queryable report row for one work item of a terminal run. Rows exist only
/// for runs terminalized after this model shipped (no backfill); the payload
/// ledger inside `PersistedRunRecord` stays the integrity-checked source of
/// truth, and these rows mirror it so item queries can use `#Predicate`
/// instead of decoding every payload.
@Model
public final class PersistedRunReportItem {
    @Attribute(.unique) public var key: String
    public var runID: UUID
    public var itemID: UUID
    public var position: Int
    /// Denormalized from the run record for date-range item queries.
    public var runStartedAt: Date
    public var changeTypeRaw: String
    /// `prepared`, `attempting`, `attempted`, or `outcome:<WorkOutcome>`.
    public var stateRaw: String
    public var artist: String
    public var album: String
    /// Empty for album-level targets.
    public var trackName: String
    /// `"track"` / `"album"`; nil only on rows persisted before the column
    /// existed. Explicit so target filters never have to read the
    /// empty-trackName sentinel as "album" — Music.app allows unnamed tracks.
    public var targetKindRaw: String?
    /// Full-fidelity `RunWorkItem` JSON.
    public var itemData: Data

    /// `itemData` is passed pre-encoded so encoding failures stay in the
    /// store; every other column derives from `item`.
    public init(runID: UUID, position: Int, runStartedAt: Date, item: RunWorkItem, itemData: Data) {
        let identity = item.target.reportIdentity
        key = Self.key(runID: runID, itemID: item.id)
        self.runID = runID
        itemID = item.id
        self.position = position
        self.runStartedAt = runStartedAt
        changeTypeRaw = item.change.changeType.rawValue
        stateRaw = Self.stateRaw(for: item.state)
        artist = identity.artist
        album = identity.album
        trackName = identity.trackName
        targetKindRaw = item.target.reportKindRaw
        self.itemData = itemData
    }

    /// Re-aligns an existing row with the payload ledger after a repair path
    /// re-terminalizes the run; columns must never diverge from the ledger.
    func apply(position: Int, runStartedAt: Date, item: RunWorkItem, itemData: Data) {
        let identity = item.target.reportIdentity
        self.position = position
        self.runStartedAt = runStartedAt
        changeTypeRaw = item.change.changeType.rawValue
        stateRaw = Self.stateRaw(for: item.state)
        artist = identity.artist
        album = identity.album
        trackName = identity.trackName
        targetKindRaw = item.target.reportKindRaw
        self.itemData = itemData
    }

    static func key(runID: UUID, itemID: UUID) -> String {
        "\(runID.uuidString):\(itemID.uuidString)"
    }

    static func stateRaw(for state: WorkState) -> String {
        switch state {
        case .prepared:
            "prepared"
        case .attempting:
            "attempting"
        case .attempted:
            "attempted"
        case let .outcome(outcome):
            "outcome:\(outcome.rawValue)"
        }
    }
}

extension WorkTarget {
    /// Denormalized report identity; album targets have no track name.
    var reportIdentity: (artist: String, album: String, trackName: String) {
        switch self {
        case let .track(identity):
            (identity.artist, identity.album, identity.trackName)
        case let .album(identity):
            (identity.artist, identity.album, "")
        }
    }

    var reportKindRaw: String {
        switch self {
        case .track:
            "track"
        case .album:
            "album"
        }
    }
}
