import Core
import Foundation

/// The probed facts browse assembly needs (ADR 0013): the scoped track
/// mirror, the immutable scope snapshot the projection is computed
/// against, the derived physical count, and the host-owned service
/// ladder for preview availability.
public struct BrowseInput: Equatable, Sendable {
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
/// comparing an artist-node name to the allow list (ADR 0020). Tracks
/// without a complete album identity are not represented: the write
/// pipeline fails fast on them, so Browse must not offer them nodes.
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

    /// Track rows for one album, derived on demand. Pure over the same
    /// input the projection was built from — DesignUI never assembles
    /// truth. O(library) per call; render paths that expand albums
    /// repeatedly must use `makeTrackRowIndex(input:)` instead.
    public static func trackRows(forAlbumID albumID: String, input: BrowseInput) -> [BrowseTrackRow] {
        let albumTracks = input.tracks.filter { track in
            let identity = AlbumIdentity(track: track)
            return identity.isComplete && identity.key == albumID
        }
        return makeRows(for: albumTracks, scope: input.scope)
    }

    /// Every album's rows in one O(library) pass, keyed by album node id.
    /// Built once per input by the host so per-album lookup is O(1) on
    /// render paths.
    public static func makeTrackRowIndex(input: BrowseInput) -> [String: [BrowseTrackRow]] {
        let groups = Dictionary(grouping: identifiedTracks(in: input.tracks)) { $0.identity.key }
        return groups.mapValues { makeRows(for: $0.map(\.track), scope: input.scope) }
    }

    // MARK: - Album nodes

    /// One identity construction per track — identity building runs
    /// feature-suffix searches, so the grouped paths pair it with the
    /// track instead of rebuilding it for filter and grouping.
    private static func identifiedTracks(in tracks: [Track]) -> [(track: Track, identity: AlbumIdentity)] {
        tracks.compactMap { track in
            let identity = AlbumIdentity(track: track)
            return identity.isComplete ? (track: track, identity: identity) : nil
        }
    }

    private static func makeAlbumNodes(input: BrowseInput) -> [BrowseAlbumNode] {
        let groups = Dictionary(grouping: identifiedTracks(in: input.tracks)) { $0.identity }
        return groups.map { identity, members in
            let tracks = members.map(\.track)
            let counts = makeCounts(for: tracks, scope: input.scope)
            return BrowseAlbumNode(
                id: identity.key,
                title: identity.album,
                artistName: identity.artist,
                genre: dominantValue(in: tracks.compactMap(\.genre)),
                year: dominantValue(in: tracks.compactMap(\.year)),
                counts: counts,
                action: makeAlbumAction(albumID: identity.key, counts: counts, input: input)
            )
        }
    }

    private static func makeCounts(for tracks: [Track], scope: ProcessingScopeSnapshot) -> BrowseNodeCounts {
        BrowseNodeCounts(
            total: tracks.count,
            inScope: tracks.count { isTrackInScope($0, scope: scope) },
            writable: tracks.count { FixPlanProjector.hasWriteID($0.appleScriptID) }
        )
    }

    /// The availability ladder, fail-closed: the host's service reason
    /// outranks the scope reason; a zero-intersection album under Test
    /// Artists disables with the boundary spelled out (analysis D2);
    /// partial intersection stays enabled with narrowing visible through
    /// the counts.
    private static func makeAlbumAction(
        albumID: String,
        counts: BrowseNodeCounts,
        input: BrowseInput
    ) -> ChromeCommandDescriptor {
        var disabledReason: String?
        if let unavailableReason = input.previewUnavailableReason {
            disabledReason = unavailableReason
        } else if input.scope.source == .testArtists, counts.inScope == 0 {
            disabledReason = "Outside the current Test Artists scope."
        }

        return ChromeCommandDescriptor(
            id: "browse-preview-\(albumID)",
            title: "Preview changes",
            isEnabled: disabledReason == nil,
            disabledReason: disabledReason,
            commandKind: .requestAlbumPreview
        )
    }

    // MARK: - Scope membership

    /// Membership through the snapshot's own matching rule. A
    /// `.testArtists` snapshot with an empty normalized list cannot be
    /// produced by `capture`, but a decoded or hand-built one fails
    /// CLOSED here: nothing is in scope, rather than everything.
    private static func isTrackInScope(_ track: Track, scope: ProcessingScopeSnapshot) -> Bool {
        switch scope.source {
        case .fullLibrary:
            return true
        case .testArtists:
            guard !scope.normalizedTestArtists.isEmpty else { return false }
            return ArtistAllowList.containsNormalized(track, in: scope.normalizedTestArtists)
        }
    }

    // MARK: - Track rows

    private static func makeRows(for tracks: [Track], scope: ProcessingScopeSnapshot) -> [BrowseTrackRow] {
        tracks
            .sorted { left, right in
                let leftPosition = left.originalPosition ?? Int.max
                let rightPosition = right.originalPosition ?? Int.max
                if leftPosition != rightPosition {
                    return leftPosition < rightPosition
                }
                let nameOrder = left.name.localizedStandardCompare(right.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return left.id < right.id
            }
            .map { track in
                BrowseTrackRow(
                    id: track.id,
                    title: track.name,
                    genre: track.genre,
                    year: track.year,
                    hasWriteIdentity: FixPlanProjector.hasWriteID(track.appleScriptID),
                    isInScope: isTrackInScope(track, scope: scope)
                )
            }
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
