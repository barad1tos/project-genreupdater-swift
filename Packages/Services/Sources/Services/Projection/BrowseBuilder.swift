import Core
import Foundation

/// Physical MusicKit presentation facts. A missing snapshot is distinct from
/// a committed empty catalog; the typed issue preserves refresh versus
/// persistence semantics for operational guidance.
public struct BrowseCatalogFacts: Equatable, Sendable {
    public let snapshot: CatalogSnapshot?
    public let source: CatalogSnapshotSource?
    public let issue: CatalogIssue?

    public init(snapshot: CatalogSnapshot?, source: CatalogSnapshotSource?, issue: CatalogIssue?) {
        self.snapshot = snapshot
        self.source = source
        self.issue = issue
    }
}

/// Canonical AppleScript-backed processing facts used only for action safety.
public struct BrowseProcessingFacts: Equatable, Sendable {
    public let tracks: [Track]
    public let readiness: MirrorReadiness

    public init(tracks: [Track], readiness: MirrorReadiness) {
        self.tracks = tracks
        self.readiness = readiness
    }
}

/// The explicitly separated inputs Browse needs: MusicKit for navigation and
/// the canonical mirror for processing authority.
public struct BrowseInput: Equatable, Sendable {
    public let catalog: BrowseCatalogFacts
    public let processing: BrowseProcessingFacts
    public let scope: ProcessingScopeSnapshot
    public let previewUnavailableReason: String?

    public init(
        catalog: BrowseCatalogFacts,
        processing: BrowseProcessingFacts,
        scope: ProcessingScopeSnapshot,
        previewUnavailableReason: String?
    ) {
        self.catalog = catalog
        self.processing = processing
        self.scope = scope
        self.previewUnavailableReason = previewUnavailableReason
    }
}

/// Pure assembly of the Browse projection. Catalog rows provide navigation;
/// only canonical mirror rows and readiness may authorize a preview command.
public enum BrowseBuilder {
    public static func makeProjection(input: BrowseInput) -> BrowseProjection {
        let catalogTracks = input.catalog.snapshot?.tracks ?? []
        let processingIndex = ProcessingIndex(tracks: input.processing.tracks)
        return BrowseProjection(
            revision: .initial,
            artists: makeArtistNodes(albums: makeAlbumNodes(
                catalogTracks: catalogTracks,
                processingIndex: processingIndex,
                input: input
            )),
            scope: makeScopeFacts(input.scope),
            physicalTrackCount: input.catalog.snapshot?.tracks.count,
            readSource: makeReadSource(catalog: input.catalog),
            operationalIssues: makeIssues(catalog: input.catalog)
        )
    }

    public static func trackRows(forAlbumID albumID: String, input: BrowseInput) -> [BrowseTrackRow] {
        let processingIndex = ProcessingIndex(tracks: input.processing.tracks)
        return identifiedCatalogTracks(in: input.catalog.snapshot?.tracks ?? [])
            .filter { $0.identity.key == albumID }
            .sorted(by: catalogTrackOrder)
            .map { makeRow(for: $0.track, processingIndex: processingIndex, input: input) }
    }

    public static func makeTrackRowIndex(input: BrowseInput) -> [String: [BrowseTrackRow]] {
        let processingIndex = ProcessingIndex(tracks: input.processing.tracks)
        let groups = Dictionary(grouping: identifiedCatalogTracks(in: input.catalog.snapshot?.tracks ?? [])) {
            $0.identity.key
        }
        return groups.mapValues { members in
            members.sorted(by: catalogTrackOrder).map {
                makeRow(for: $0.track, processingIndex: processingIndex, input: input)
            }
        }
    }

    private struct ProcessingIndex {
        let tracksByAlbum: [AlbumIdentity: [Track]]
        let tracksByAlbumTitle: [AlbumIdentity: [String: [Track]]]

        init(tracks: [Track]) {
            var albumTracks: [AlbumIdentity: [Track]] = [:]
            var albumTitleTracks: [AlbumIdentity: [String: [Track]]] = [:]
            for track in tracks {
                let title = normalizeForMatching(track.name)
                for album in AlbumIdentity.lookupCandidates(for: track) {
                    albumTracks[album, default: []].append(track)
                    albumTitleTracks[album, default: [:]][title, default: []].append(track)
                }
            }
            tracksByAlbum = albumTracks
            tracksByAlbumTitle = albumTitleTracks
        }
    }

    private static func identifiedCatalogTracks(
        in tracks: [CatalogTrack]
    ) -> [(track: CatalogTrack, position: Int, identity: AlbumIdentity)] {
        tracks.enumerated().compactMap { position, track in
            let identity = catalogAlbumIdentity(track)
            return identity.isComplete ? (track, position, identity) : nil
        }
    }

    private static func catalogTrackOrder(
        _ left: (track: CatalogTrack, position: Int, identity: AlbumIdentity),
        _ right: (track: CatalogTrack, position: Int, identity: AlbumIdentity)
    ) -> Bool {
        let titleOrder = left.track.title.localizedStandardCompare(right.track.title)
        return titleOrder == .orderedSame ? left.position < right.position : titleOrder == .orderedAscending
    }

    private static func catalogAlbumIdentity(_ track: CatalogTrack) -> AlbumIdentity {
        AlbumIdentity(
            artist: AlbumIdentity.groupingArtist(artist: track.artist, albumArtist: track.albumArtist),
            album: track.album
        )
    }

    private static func makeAlbumNodes(
        catalogTracks: [CatalogTrack],
        processingIndex: ProcessingIndex,
        input: BrowseInput
    ) -> [BrowseAlbumNode] {
        let groups = Dictionary(grouping: identifiedCatalogTracks(in: catalogTracks)) { $0.identity }
        return groups.map { identity, members in
            let tracks = members.map(\.track)
            let processingTracks = processingIndex.tracksByAlbum[identity] ?? []
            let counts = makeCounts(
                catalogTracks: tracks,
                processingTracks: processingTracks,
                scope: input.scope
            )
            return BrowseAlbumNode(
                id: identity.key,
                title: identity.album,
                artistName: identity.artist,
                genre: dominantValue(in: tracks.flatMap(\.genres)),
                year: dominantValue(in: tracks.compactMap(\.dates.releaseYear)),
                counts: counts,
                action: makeAlbumAction(
                    albumID: identity.key,
                    processingTracks: processingTracks,
                    counts: counts,
                    input: input
                )
            )
        }
    }

    private static func makeCounts(
        catalogTracks: [CatalogTrack],
        processingTracks: [Track],
        scope: ProcessingScopeSnapshot
    ) -> BrowseNodeCounts {
        BrowseNodeCounts(
            total: catalogTracks.count,
            inScope: processingTracks.count { isProcessingTrackInScope($0, scope: scope) },
            writable: processingTracks.count { FixPlanProjector.hasWriteID($0.appleScriptID) }
        )
    }

    private static func makeAlbumAction(
        albumID: String,
        processingTracks: [Track],
        counts: BrowseNodeCounts,
        input: BrowseInput
    ) -> ChromeCommandDescriptor {
        let disabledReason: String? = if let unavailableReason = input.previewUnavailableReason {
            unavailableReason
        } else if !input.processing.readiness.isReady {
            ProcessingAdmissionRejection.mirror(input.processing.readiness).localizedDescription
        } else if processingTracks.isEmpty {
            "Processing metadata isn’t available for this album yet."
        } else if input.scope.source == .testArtists, counts.inScope == 0 {
            "Outside the current Test Artists scope."
        } else {
            nil
        }

        return ChromeCommandDescriptor(
            id: "browse-preview-\(albumID)",
            title: "Preview changes",
            isEnabled: disabledReason == nil,
            disabledReason: disabledReason,
            commandKind: .requestAlbumPreview
        )
    }

    private static func makeRow(
        for track: CatalogTrack,
        processingIndex: ProcessingIndex,
        input: BrowseInput
    ) -> BrowseTrackRow {
        let album = catalogAlbumIdentity(track)
        let title = normalizeForMatching(track.title)
        let matchingRows = processingIndex.tracksByAlbumTitle[album]?[title] ?? []
        let verifiedRow = matchingRows.count == 1 ? matchingRows[0] : nil
        return BrowseTrackRow(
            id: track.id.displayValue,
            title: track.title,
            genre: track.genres.first,
            year: track.dates.releaseYear,
            hasWriteIdentity: verifiedRow.map { FixPlanProjector.hasWriteID($0.appleScriptID) } ?? false,
            isInScope: isCatalogTrackInScope(track, scope: input.scope)
        )
    }

    private static func isCatalogTrackInScope(_ track: CatalogTrack, scope: ProcessingScopeSnapshot) -> Bool {
        switch scope.source {
        case .fullLibrary:
            return true
        case .testArtists:
            guard !scope.normalizedTestArtists.isEmpty else { return false }
            return ArtistAllowList.containsNormalized(
                artist: track.artist,
                albumArtist: track.albumArtist,
                in: scope.normalizedTestArtists
            )
        }
    }

    private static func isProcessingTrackInScope(_ track: Track, scope: ProcessingScopeSnapshot) -> Bool {
        switch scope.source {
        case .fullLibrary:
            return true
        case .testArtists:
            guard !scope.normalizedTestArtists.isEmpty else { return false }
            return ArtistAllowList.containsNormalized(track, in: scope.normalizedTestArtists)
        }
    }

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

    private static func makeReadSource(catalog: BrowseCatalogFacts) -> BrowseReadSource? {
        guard let snapshot = catalog.snapshot, let source = catalog.source else { return nil }
        switch source {
        case .live:
            return .liveCatalog(capturedAt: snapshot.capturedAt)
        case .persisted:
            return .persistedCatalog(capturedAt: snapshot.capturedAt)
        }
    }

    private static func makeIssues(catalog: BrowseCatalogFacts) -> [OperationalIssue] {
        guard let issue = catalog.issue else { return [] }
        switch issue {
        case let .refreshFailed(message):
            return [OperationalIssue(
                id: "browse.catalog-refresh",
                category: .musicKitUnavailable,
                summary: catalog.snapshot == nil
                    ? "The Music catalog is unavailable."
                    : "The Music catalog may be out of date.",
                technicalDetail: message,
                nextAction: "Refresh the library to retry the Music catalog read."
            )]
        case let .persistenceFailed(message):
            return [OperationalIssue(
                id: "browse.catalog-persistence",
                category: .temporaryUnavailable,
                summary: "The current Music catalog couldn’t be saved.",
                technicalDetail: message,
                nextAction: "Refresh the library to retry saving it."
            )]
        case let .recoveryFailed(message):
            return [OperationalIssue(
                id: "browse.catalog-recovery",
                category: .internalFailure,
                summary: "The saved Music catalog couldn’t be loaded.",
                technicalDetail: message,
                nextAction: "Refresh the library to rebuild the saved catalog."
            )]
        }
    }

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
