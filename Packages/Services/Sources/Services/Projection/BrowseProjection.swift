import Core
import Foundation

/// One track as Browse detail truth: inspection metadata plus the two
/// safety facts every row must render (ADR 0019).
public struct BrowseTrackRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let genre: String?
    public let year: Int?
    /// Mirrors the fix-plan write-ID rule: a non-empty AppleScript ID.
    public let hasWriteIdentity: Bool
    public let isInScope: Bool

    public init(id: String, title: String, genre: String?, year: Int?, hasWriteIdentity: Bool, isInScope: Bool) {
        self.id = id
        self.title = title
        self.genre = genre
        self.year = year
        self.hasWriteIdentity = hasWriteIdentity
        self.isInScope = isInScope
    }
}

/// Track tallies for a browse node, grouped so no initializer grows past
/// the parameter ceiling.
public struct BrowseNodeCounts: Equatable, Sendable {
    public let total: Int
    public let inScope: Int
    public let writable: Int

    public init(total: Int, inScope: Int, writable: Int) {
        self.total = total
        self.inScope = inScope
        self.writable = writable
    }
}

/// An album node keyed by the normalized `AlbumIdentity` key — the same
/// alias-tolerant identity the write pipeline uses, so cross-surface
/// references stay stable (ADR 0019).
public struct BrowseAlbumNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let artistName: String
    public let genre: String?
    public let year: Int?
    public let counts: BrowseNodeCounts
    /// The album's only affordance: a preview request whose availability
    /// truth always carries its reason (ADR 0014; analysis D3).
    public let action: ChromeCommandDescriptor

    public init(
        id: String,
        title: String,
        artistName: String,
        genre: String?,
        year: Int?,
        counts: BrowseNodeCounts,
        action: ChromeCommandDescriptor
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.genre = genre
        self.year = year
        self.counts = counts
        self.action = action
    }
}

/// An artist node keyed by the normalized grouping artist. Counts are
/// computed so the aggregate can never disagree with the albums.
public struct BrowseArtistNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let albums: [BrowseAlbumNode]

    public init(id: String, name: String, albums: [BrowseAlbumNode]) {
        self.id = id
        self.name = name
        self.albums = albums
    }

    public var counts: BrowseNodeCounts {
        BrowseNodeCounts(
            total: albums.reduce(0) { $0 + $1.counts.total },
            inScope: albums.reduce(0) { $0 + $1.counts.inScope },
            writable: albums.reduce(0) { $0 + $1.counts.writable }
        )
    }
}

/// The immutable scope the projection was computed against (ADR 0020):
/// snapshot identity for command staleness plus the shared display
/// summary vocabulary.
public struct BrowseScopeFacts: Equatable, Sendable {
    public let snapshotID: UUID
    public let fingerprint: String
    public let summary: ChromeScopeSummary

    public init(snapshotID: UUID, fingerprint: String, summary: ChromeScopeSummary) {
        self.snapshotID = snapshotID
        self.fingerprint = fingerprint
        self.summary = summary
    }
}

/// Where the browse read came from, so Browse never implies a fresher
/// truth than it has.
public enum BrowseReadSource: Equatable, Sendable {
    /// The persisted mirror records no scan date today; nil stays honest.
    case cachedMirror(scannedAt: Date?)
}

/// The Browse surface truth (ADR 0012): the scoped library index with
/// per-node scope membership and action availability. Track rows derive
/// on demand through `BrowseBuilder` and are never stored here. The
/// physical count is a labeled derived copy of Chrome truth, never a
/// second source.
public struct BrowseProjection: Equatable, Sendable {
    public let revision: ProjectionRevision
    public let artists: [BrowseArtistNode]
    public let scope: BrowseScopeFacts?
    public let physicalTrackCount: Int?
    public let readSource: BrowseReadSource?
    public let operationalIssues: [OperationalIssue]

    public init(
        revision: ProjectionRevision,
        artists: [BrowseArtistNode],
        scope: BrowseScopeFacts?,
        physicalTrackCount: Int?,
        readSource: BrowseReadSource?,
        operationalIssues: [OperationalIssue]
    ) {
        self.revision = revision
        self.artists = artists
        self.scope = scope
        self.physicalTrackCount = physicalTrackCount
        self.readSource = readSource
        self.operationalIssues = operationalIssues
    }

    public static func empty(revision: ProjectionRevision = .initial) -> Self {
        Self(
            revision: revision,
            artists: [],
            scope: nil,
            physicalTrackCount: nil,
            readSource: nil,
            operationalIssues: []
        )
    }

    func withRevision(_ revision: ProjectionRevision) -> Self {
        Self(
            revision: revision,
            artists: artists,
            scope: scope,
            physicalTrackCount: physicalTrackCount,
            readSource: readSource,
            operationalIssues: operationalIssues
        )
    }
}
