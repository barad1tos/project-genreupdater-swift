import Core
import Foundation

/// The identity of a track captured verbatim at fix-plan proposal time, so a
/// persisted item stays a faithful snapshot even if the underlying track later
/// changes (renamed, re-enriched, or removed from the library).
public struct FixPlanItemIdentity: Codable, Equatable, Sendable {
    /// `Track.id` — MusicKit read identity (ADR 0018).
    public let readID: String
    /// Write identity when known at proposal time (ADR 0019).
    public let appleScriptID: String?
    public let artist: String
    public let album: String
    public let trackName: String

    public init(
        readID: String,
        appleScriptID: String?,
        artist: String,
        album: String,
        trackName: String
    ) {
        self.readID = readID
        self.appleScriptID = appleScriptID
        self.artist = artist
        self.album = album
        self.trackName = trackName
    }
}

/// One proposed metadata change captured into an immutable fix plan (ADR 0017).
///
/// Mirrors `ProposedChange` at proposal time, minus acceptance — acceptance is
/// tracked separately by `FixPlanReviewDecision` so review state can change
/// without mutating the plan itself.
public struct FixPlanItem: Codable, Equatable, Sendable, Identifiable {
    /// Preserved from `ProposedChange.id`.
    public let id: UUID
    public let identity: FixPlanItemIdentity
    public let changeType: ChangeType
    public let oldValue: String?
    public let newValue: String?
    public let confidence: Int
    public let source: String

    public init(
        id: UUID,
        identity: FixPlanItemIdentity,
        changeType: ChangeType,
        oldValue: String?,
        newValue: String?,
        confidence: Int,
        source: String
    ) {
        self.id = id
        self.identity = identity
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.confidence = confidence
        self.source = source
    }
}

/// An immutable snapshot of the exact proposal GenreUpdater showed the user at a
/// specific moment (ADR 0017). Items never mutate after creation; acceptance and
/// rejection are recorded separately by `FixPlanReviewDecision`.
public struct FixPlan: Equatable, Sendable {
    public let id: FixPlanID
    public let revision: FixPlanRevision
    /// Required — ADR 0017: every fix plan traces back to the run that produced it.
    public let sourceRunID: RunID
    public let createdAt: Date
    public let configuration: FixPlanConfig
    public let scope: ProcessingScopeSnapshot
    public let items: [FixPlanItem]

    public init(
        id: FixPlanID,
        revision: FixPlanRevision,
        sourceRunID: RunID,
        createdAt: Date,
        configuration: FixPlanConfig,
        scope: ProcessingScopeSnapshot,
        items: [FixPlanItem]
    ) {
        self.id = id
        self.revision = revision
        self.sourceRunID = sourceRunID
        self.createdAt = createdAt
        self.configuration = configuration
        self.scope = scope
        self.items = items
    }
}
