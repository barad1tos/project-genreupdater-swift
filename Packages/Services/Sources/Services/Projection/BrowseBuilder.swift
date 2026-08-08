import Core
import Foundation

/// The probed facts browse assembly needs (ADR 0013): the scoped track
/// mirror, the immutable scope snapshot the projection is computed
/// against, the derived physical count, and the host-owned service
/// ladder for preview availability.
public struct BrowseInput: Sendable {
    public let tracks: [Track]
    public let scope: ProcessingScopeSnapshot
    public let physicalTrackCount: Int?
    public let readSource: BrowseReadSource
    public let previewUnavailableReason: String?

    public init(
        tracks: [Track],
        scope: ProcessingScopeSnapshot,
        physicalTrackCount: Int?,
        readSource: BrowseReadSource,
        previewUnavailableReason: String?
    ) {
        self.tracks = tracks
        self.scope = scope
        self.physicalTrackCount = physicalTrackCount
        self.readSource = readSource
        self.previewUnavailableReason = previewUnavailableReason
    }
}

/// Pure assembly of the Browse projection. Scope membership is decided
/// per track through the snapshot's own matching rule — never by
/// comparing an artist-node name to the allow list (ADR 0020).
public enum BrowseBuilder {
    public static func makeProjection(input: BrowseInput) -> BrowseProjection {
        BrowseProjection(
            revision: .initial,
            artists: makeArtistNodes(albums: makeAlbumNodes(input: input)),
            scope: makeScopeFacts(input.scope),
            physicalTrackCount: input.physicalTrackCount,
            readSource: input.readSource,
            operationalIssues: []
        )
    }

    // MARK: - Album nodes

    private static func makeAlbumNodes(input: BrowseInput) -> [BrowseAlbumNode] {
        let groups = Dictionary(grouping: input.tracks) { AlbumIdentity(track: $0) }
        return groups.map { identity, tracks in
            BrowseAlbumNode(
                id: identity.key,
                title: identity.album,
                artistName: identity.artist,
                genre: dominantValue(in: tracks.compactMap(\.genre)),
                year: dominantValue(in: tracks.compactMap(\.year)),
                counts: makeCounts(for: tracks, scope: input.scope),
                action: makeAlbumAction(albumID: identity.key)
            )
        }
    }

    private static func makeCounts(for tracks: [Track], scope: ProcessingScopeSnapshot) -> BrowseNodeCounts {
        BrowseNodeCounts(
            total: tracks.count,
            inScope: tracks.count { ArtistAllowList.contains($0, in: scope.normalizedTestArtists) },
            writable: tracks.count { hasWriteIdentity($0) }
        )
    }

    private static func makeAlbumAction(albumID: String) -> ChromeCommandDescriptor {
        ChromeCommandDescriptor(
            id: "browse-preview-\(albumID)",
            title: "Preview changes",
            isEnabled: true,
            commandKind: .requestAlbumPreview
        )
    }

    private static func hasWriteIdentity(_ track: Track) -> Bool {
        guard let appleScriptID = track.appleScriptID else { return false }
        return !appleScriptID.isEmpty
    }

    // MARK: - Artist nodes

    private static func makeArtistNodes(albums: [BrowseAlbumNode]) -> [BrowseArtistNode] {
        let groups = Dictionary(grouping: albums) { normalizeForMatching($0.artistName) }
        let artists = groups.map { normalizedArtist, memberAlbums in
            BrowseArtistNode(
                id: normalizedArtist,
                name: dominantValue(in: memberAlbums.map(\.artistName)) ?? normalizedArtist,
                albums: sortedAlbums(memberAlbums)
            )
        }
        return artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func sortedAlbums(_ albums: [BrowseAlbumNode]) -> [BrowseAlbumNode] {
        albums.sorted { left, right in
            let leftYear = left.year ?? Int.max
            let rightYear = right.year ?? Int.max
            if leftYear != rightYear {
                return leftYear < rightYear
            }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    // MARK: - Scope facts

    private static func makeScopeFacts(_ scope: ProcessingScopeSnapshot) -> BrowseScopeFacts {
        BrowseScopeFacts(
            snapshotID: scope.id,
            fingerprint: scope.fingerprint,
            summary: ChromeScopeSummary(
                sourceLabel: ReportsRunLabels.scopeSourceLabel(for: scope),
                detailLabel: scope.source == .testArtists
                    ? scope.normalizedTestArtists.joined(separator: ", ")
                    : nil,
                isNarrowedFromPhysical: scope.source == .testArtists
            )
        )
    }

    // MARK: - Helpers

    /// The most frequent value; ties resolve to the smallest so display
    /// aggregation stays deterministic and pinnable.
    private static func dominantValue<Value: Hashable & Comparable>(in values: [Value]) -> Value? {
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.min { left, right in
            if left.value != right.value {
                return left.value > right.value
            }
            return left.key < right.key
        }?.key
    }
}
