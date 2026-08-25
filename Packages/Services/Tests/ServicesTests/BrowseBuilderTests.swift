import Core
import Foundation
import Testing
@testable import Services

// MARK: - Fixtures

private func makeTrack(
    id: String = UUID().uuidString,
    name: String = "Song",
    artist: String,
    album: String,
    albumArtist: String? = nil,
    genre: String? = nil,
    year: Int? = nil,
    originalPosition: Int? = nil,
    appleScriptID: String? = "as-id"
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        originalPosition: originalPosition,
        albumArtist: albumArtist,
        appleScriptID: appleScriptID
    )
}

private func makeInput(
    tracks: [Track],
    testArtists: [String] = [],
    physicalTrackCount: Int? = nil,
    readSource: BrowseReadSource = .cachedMirror(scannedAt: Date(timeIntervalSince1970: 100)),
    previewUnavailableReason: String? = nil
) -> BrowseInput {
    BrowseInput(
        tracks: tracks,
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: testArtists,
            knownTrackCount: tracks.count,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "browse-test"
        ),
        physicalTrackCount: physicalTrackCount,
        readSource: readSource,
        previewUnavailableReason: previewUnavailableReason
    )
}

// MARK: - Grouping

@Suite("Browse builder grouping")
struct BrowseBuilderGroupingTests {
    @Test("albumArtist groups a split-artist album into one node")
    func albumArtistWinsGrouping() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Artist feat. Guest", album: "One", albumArtist: "Artist"),
            makeTrack(artist: "Artist", album: "One", albumArtist: "Artist"),
        ]))

        #expect(projection.artists.count == 1)
        #expect(projection.artists[0].albums.count == 1)
        #expect(projection.artists[0].albums[0].counts.total == 2)
    }

    @Test("case variants merge into one artist node with a stable id")
    func caseVariantsMerge() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Metallica", album: "Ride the Lightning"),
            makeTrack(artist: "metallica", album: "Kill 'Em All"),
        ]))

        #expect(projection.artists.count == 1)
        let artist = projection.artists[0]
        #expect(artist.id == normalizeForMatching("Metallica"))
        #expect(artist.name == "Metallica")
        #expect(artist.albums.count == 2)
    }

    @Test("a The-prefixed spelling groups separately by design")
    func thePrefixSplitsByDesign() {
        // Canonical grouping is trim+lowercase only: "The Beatles" and
        // "Beatles" are different artists to scope matching, so browse
        // must not merge them either (analysis S6).
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "The Beatles", album: "Abbey Road"),
            makeTrack(artist: "Beatles", album: "Revolver"),
        ]))

        #expect(projection.artists.count == 2)
    }

    @Test("the album id is the normalized AlbumIdentity key")
    func albumIDIsIdentityKey() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Clutch", album: "Blast Tyrant"),
        ]))

        let expectedKey = AlbumIdentity(artist: "Clutch", album: "Blast Tyrant").key
        let album = projection.artists[0].albums[0]
        #expect(album.id == expectedKey)
        #expect(album.action.commandKind == .requestAlbumPreview)
        #expect(album.action.id == "browse-preview-\(expectedKey)")
    }

    @Test("tracks without a complete album identity get no node")
    func incompleteIdentitySkipped() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Artist", album: ""),
            makeTrack(artist: "   ", album: "Orphan"),
            makeTrack(artist: "Artist", album: "Kept"),
        ]))

        #expect(projection.artists.count == 1)
        #expect(projection.artists[0].albums.map(\.title) == ["Kept"])
    }

    @Test("an empty mirror still carries scope, read source, and count facts")
    func emptyTracksKeepsFacts() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(
            tracks: [],
            testArtists: ["Clutch"],
            physicalTrackCount: 10,
            readSource: .cachedMirror(scannedAt: Date(timeIntervalSince1970: 50))
        ))

        #expect(projection.artists.isEmpty)
        #expect(projection.scope?.summary.sourceLabel == "Test artists (1)")
        #expect(projection.physicalTrackCount == 10)
        #expect(projection.readSource == .cachedMirror(scannedAt: Date(timeIntervalSince1970: 50)))
    }

    @Test("the same album title under different artists yields two nodes")
    func sameTitleDifferentArtists() {
        let input = makeInput(tracks: [
            makeTrack(id: "a-track", artist: "Alpha", album: "Greatest Hits"),
            makeTrack(id: "b-track", artist: "Beta", album: "Greatest Hits"),
        ])
        let projection = BrowseBuilder.makeProjection(input: input)

        #expect(projection.artists.count == 2)
        let alphaRows = BrowseBuilder.trackRows(
            forAlbumID: AlbumIdentity(artist: "Alpha", album: "Greatest Hits").key,
            input: input
        )
        #expect(alphaRows.map(\.id) == ["a-track"])
    }

    @Test("the majority spelling wins the artist display name")
    func majorityCasingWins() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "metallica", album: "One"),
            makeTrack(artist: "metallica", album: "Two"),
            makeTrack(artist: "Metallica", album: "Three"),
        ]))

        #expect(projection.artists[0].name == "metallica")
    }

    @Test("display genre and year are the most frequent values, ties smallest")
    func dominantDisplayValues() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Artist", album: "One", genre: "Rock", year: 2004),
            makeTrack(artist: "Artist", album: "One", genre: "Rock", year: 2004),
            makeTrack(artist: "Artist", album: "One", genre: "Jazz", year: nil),
            makeTrack(artist: "Artist", album: "Two", genre: "Rock", year: 2001),
            makeTrack(artist: "Artist", album: "Two", genre: "Jazz", year: 1999),
        ]))

        let albums = projection.artists[0].albums
        let one = albums.first { $0.title == "One" }
        let two = albums.first { $0.title == "Two" }

        #expect(one?.genre == "Rock")
        #expect(one?.year == 2004)
        // A 1-1 tie resolves to the smallest value.
        #expect(two?.genre == "Jazz")
        #expect(two?.year == 1999)
    }

    @Test("artists sort by name, albums by year then title, unknown year last")
    func sortOrder() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Beatles", album: "Revolver", year: 1966),
            makeTrack(artist: "Anthrax", album: "Zeta", year: 2001),
            makeTrack(artist: "Anthrax", album: "Beta", year: 1999),
            makeTrack(artist: "Anthrax", album: "Alpha", year: nil),
        ]))

        #expect(projection.artists.map(\.name) == ["Anthrax", "Beatles"])
        #expect(projection.artists[0].albums.map(\.title) == ["Beta", "Zeta", "Alpha"])
    }
}

// MARK: - Scope truth

@Suite("Browse builder scope truth")
struct BrowseBuilderScopeTests {
    @Test("membership is per track, never per node name")
    func membershipIsPerTrack() {
        // Identity normalization strips the feature suffix, so both tracks
        // land in one album node whose artist name matches the allow list.
        // Scope matching compares the full effectiveArtist — the featured
        // track stays out. A node-name comparison would claim 2 of 2.
        let projection = BrowseBuilder.makeProjection(input: makeInput(
            tracks: [
                makeTrack(artist: "The Beatles", album: "Abbey Road"),
                makeTrack(artist: "The Beatles feat. Billy Preston", album: "Abbey Road"),
            ],
            testArtists: ["The Beatles"]
        ))

        #expect(projection.artists.count == 1)
        let album = projection.artists[0].albums[0]
        #expect(album.counts.total == 2)
        #expect(album.counts.inScope == 1)
        // Partial intersection keeps the action enabled; narrowing stays
        // visible through the counts.
        #expect(album.action.isEnabled)
    }

    @Test("a fully out-of-scope album is disabled with the scope reason")
    func outOfScopeAlbumDisabled() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(
            tracks: [makeTrack(artist: "Other", album: "Elsewhere")],
            testArtists: ["Clutch"]
        ))

        let album = projection.artists[0].albums[0]
        #expect(album.counts.inScope == 0)
        #expect(album.action.isEnabled == false)
        #expect(album.action.disabledReason == "Outside the current Test Artists scope.")
    }

    @Test("a full-library scope keeps every album enabled and unnarrowed")
    func fullLibraryScope() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(
            tracks: [makeTrack(artist: "Anyone", album: "Anything")]
        ))

        let album = projection.artists[0].albums[0]
        #expect(album.counts.inScope == album.counts.total)
        #expect(album.action.isEnabled)
        #expect(projection.scope?.summary.isNarrowedFromPhysical == false)
        #expect(projection.scope?.summary.sourceLabel == "Full library")
        #expect(projection.scope?.summary.detailLabel == nil)
    }

    @Test("the unavailability reason outranks the scope reason")
    func unavailabilityWins() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(
            tracks: [makeTrack(artist: "Other", album: "Elsewhere")],
            testArtists: ["Clutch"],
            previewUnavailableReason: "Services are still starting."
        ))

        let album = projection.artists[0].albums[0]
        #expect(album.action.isEnabled == false)
        #expect(album.action.disabledReason == "Services are still starting.")
    }

    @Test("scope facts carry the snapshot identity and shared labels")
    func scopeFactsCarrySnapshot() {
        let input = makeInput(
            tracks: [makeTrack(artist: "Clutch", album: "Blast Tyrant")],
            testArtists: ["Clutch"]
        )
        let projection = BrowseBuilder.makeProjection(input: input)

        #expect(projection.scope?.snapshotID == input.scope.id)
        #expect(projection.scope?.fingerprint == input.scope.fingerprint)
        #expect(projection.scope?.summary.sourceLabel == "Test artists (1)")
        #expect(projection.scope?.summary.detailLabel == "Clutch")
        #expect(projection.scope?.summary.isNarrowedFromPhysical == true)
    }

    @Test("writable counts mirror the fix-plan write-id rule")
    func writableCounts() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(tracks: [
            makeTrack(artist: "Artist", album: "One", appleScriptID: nil),
            makeTrack(artist: "Artist", album: "One", appleScriptID: ""),
            makeTrack(artist: "Artist", album: "One", appleScriptID: "   "),
            makeTrack(artist: "Artist", album: "One", appleScriptID: "as-1"),
        ]))

        // A whitespace-only ID is not writable — the fix plan trims.
        #expect(projection.artists[0].albums[0].counts.writable == 1)
    }

    @Test("the service reason disables even a fully in-scope album")
    func serviceReasonDisablesInScope() {
        let projection = BrowseBuilder.makeProjection(input: makeInput(
            tracks: [makeTrack(artist: "Anyone", album: "Anything")],
            previewUnavailableReason: "Services are still starting."
        ))

        let album = projection.artists[0].albums[0]
        #expect(album.counts.inScope == album.counts.total)
        #expect(album.action.isEnabled == false)
        #expect(album.action.disabledReason == "Services are still starting.")
    }

    @Test("a testArtists snapshot with an empty list fails closed")
    func degenerateSnapshotFailsClosed() {
        // capture() cannot produce this shape; a decoded or hand-built
        // snapshot can. Nothing may be in scope then.
        let degenerateScope = ProcessingScopeSnapshot(
            createdAt: Date(timeIntervalSince1970: 100),
            source: .testArtists,
            normalizedTestArtists: [],
            matchingRule: "Core.ArtistAllowList.effectiveArtist.localizedCaseInsensitiveCompare",
            knownTrackCount: 1,
            fingerprint: "degenerate",
            reason: "browse-test"
        )
        let projection = BrowseBuilder.makeProjection(input: BrowseInput(
            tracks: [makeTrack(artist: "Anyone", album: "Anything")],
            scope: degenerateScope,
            physicalTrackCount: nil,
            readSource: .cachedMirror(scannedAt: Date(timeIntervalSince1970: 100)),
            previewUnavailableReason: nil
        ))

        let album = projection.artists[0].albums[0]
        #expect(album.counts.inScope == 0)
        #expect(album.action.isEnabled == false)
        #expect(album.action.disabledReason == "Outside the current Test Artists scope.")
    }
}

// MARK: - Track rows

@Suite("Browse builder track rows")
struct BrowseBuilderTrackRowTests {
    @Test("rows order by position, then name, unknown position last")
    func rowOrder() {
        let rows = BrowseBuilder.trackRows(
            forAlbumID: AlbumIdentity(artist: "Artist", album: "One").key,
            input: makeInput(tracks: [
                makeTrack(name: "Closer", artist: "Artist", album: "One", originalPosition: nil),
                makeTrack(name: "Opener", artist: "Artist", album: "One", originalPosition: 1),
                makeTrack(name: "Middle", artist: "Artist", album: "One", originalPosition: 2),
                makeTrack(name: "Bonus", artist: "Artist", album: "One", originalPosition: nil),
            ])
        )

        #expect(rows.map(\.title) == ["Opener", "Middle", "Bonus", "Closer"])
    }

    @Test("rows carry per-track write identity and scope membership")
    func rowSafetyFacts() {
        let rows = BrowseBuilder.trackRows(
            forAlbumID: AlbumIdentity(artist: "The Beatles", album: "Abbey Road").key,
            input: makeInput(
                tracks: [
                    makeTrack(
                        name: "Something",
                        artist: "The Beatles",
                        album: "Abbey Road",
                        genre: "Rock",
                        year: 1969,
                        originalPosition: 1
                    ),
                    makeTrack(
                        name: "Get Back",
                        artist: "The Beatles feat. Billy Preston",
                        album: "Abbey Road",
                        originalPosition: 2,
                        appleScriptID: nil
                    ),
                ],
                testArtists: ["The Beatles"]
            )
        )

        #expect(rows.count == 2)
        #expect(rows[0].hasWriteIdentity && rows[0].isInScope)
        #expect(rows[0].genre == "Rock")
        #expect(rows[0].year == 1969)
        #expect(!rows[1].hasWriteIdentity && !rows[1].isInScope)
    }

    @Test("an unknown album id returns no rows")
    func unknownAlbum() {
        let rows = BrowseBuilder.trackRows(
            forAlbumID: "missing",
            input: makeInput(tracks: [makeTrack(artist: "Artist", album: "One")])
        )

        #expect(rows.isEmpty)
    }

    @Test("albumArtist-driven grouping reaches rows the same way it reaches nodes")
    func albumArtistAliasRows() {
        let rows = BrowseBuilder.trackRows(
            forAlbumID: AlbumIdentity(artist: "Artist", album: "Split").key,
            input: makeInput(tracks: [
                makeTrack(artist: "Someone Else", album: "Split", albumArtist: "Artist"),
                makeTrack(artist: "Another One", album: "Split", albumArtist: "Artist"),
            ])
        )

        // If rows filtered by raw artist instead of AlbumIdentity, the
        // detail pane would disagree with the node's counts.
        #expect(rows.count == 2)
    }

    @Test("scope membership does not depend on the read source")
    func cachedMirrorMembershipSame() {
        let albumID = AlbumIdentity(artist: "The Beatles", album: "Abbey Road").key
        let tracks = [
            makeTrack(artist: "The Beatles", album: "Abbey Road", originalPosition: 1),
            makeTrack(artist: "The Beatles feat. Billy Preston", album: "Abbey Road", originalPosition: 2),
        ]

        let liveRows = BrowseBuilder.trackRows(
            forAlbumID: albumID,
            input: makeInput(tracks: tracks, testArtists: ["The Beatles"])
        )
        let cachedRows = BrowseBuilder.trackRows(
            forAlbumID: albumID,
            input: makeInput(
                tracks: tracks,
                testArtists: ["The Beatles"],
                readSource: .cachedMirror(scannedAt: Date(timeIntervalSince1970: 50))
            )
        )

        #expect(liveRows.map(\.isInScope) == [true, false])
        #expect(cachedRows.map(\.isInScope) == liveRows.map(\.isInScope))
    }

    @Test("the track-row index matches per-album rows")
    func trackRowIndexMatchesPerAlbum() {
        let input = makeInput(tracks: [
            makeTrack(artist: "Alpha", album: "One", originalPosition: 2),
            makeTrack(artist: "Alpha", album: "One", originalPosition: 1),
            makeTrack(artist: "Beta", album: "Two"),
            makeTrack(artist: "Incomplete", album: ""),
        ])

        let index = BrowseBuilder.makeTrackRowIndex(input: input)

        #expect(index.count == 2)
        for albumID in index.keys {
            #expect(index[albumID] == BrowseBuilder.trackRows(forAlbumID: albumID, input: input))
        }
    }
}
