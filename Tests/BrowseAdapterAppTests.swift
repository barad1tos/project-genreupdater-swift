import Core
import DesignUI
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Browse adapter mapping")
@MainActor
struct BrowseAdapterAppTests {
    private func makeProjection() -> BrowseProjection {
        BrowseBuilder.makeProjection(input: BrowseInput(
            tracks: [
                Track(
                    id: "t1",
                    name: "The Regulator",
                    artist: "Clutch",
                    album: "Blast Tyrant",
                    genre: "Rock",
                    year: 2004,
                    originalPosition: 2,
                    appleScriptID: "as-1"
                ),
                Track(
                    id: "t2",
                    name: "Profits of Doom",
                    artist: "Clutch feat. Guest",
                    album: "Blast Tyrant",
                    originalPosition: 1,
                    appleScriptID: nil
                ),
            ],
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Clutch"],
                knownTrackCount: 2,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "adapter-test"
            ),
            physicalTrackCount: 40,
            readSource: .liveLibrary(scannedAt: Date(timeIntervalSince1970: 100)),
            previewUnavailableReason: nil
        ))
    }

    @Test("browse nodes map field-for-field onto the design vocabulary")
    func nodesMapFieldForField() {
        let projection = makeProjection()

        let artists = ActivitySnapshotAdapter.makeBrowseArtists(from: projection)

        #expect(artists.count == 1)
        #expect(artists[0].name == "Clutch")
        let album = artists[0].albums[0]
        #expect(album.name == "Blast Tyrant")
        #expect(album.artistName == "Clutch")
        #expect(album.genre == "Rock")
        #expect(album.year == 2004)
        #expect(album.counts == DesignBrowseCounts(tracks: 2, inScope: 1, writable: 1))
        #expect(album.action.title == "Preview changes")
        #expect(album.action.isEnabled)
        #expect(album.action.disabledReason == nil)
    }

    @Test("a disabled action's reason survives the mapping")
    func disabledReasonSurvives() {
        let projection = BrowseBuilder.makeProjection(input: BrowseInput(
            tracks: [Track(id: "t", name: "Song", artist: "Other", album: "Elsewhere")],
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Clutch"],
                knownTrackCount: 1,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "adapter-test"
            ),
            physicalTrackCount: nil,
            readSource: .liveLibrary(scannedAt: Date(timeIntervalSince1970: 100)),
            previewUnavailableReason: nil
        ))

        let album = ActivitySnapshotAdapter.makeBrowseArtists(from: projection)[0].albums[0]

        #expect(album.action.isEnabled == false)
        #expect(album.action.disabledReason == "Outside the current Test Artists scope.")
    }

    @Test("scope facts map onto the browse banner")
    func scopeFactsMap() {
        let scope = ActivitySnapshotAdapter.makeBrowseScope(from: makeProjection())

        #expect(scope?.sourceLabel == "Test artists (1)")
        #expect(scope?.detailLabel == "Clutch")
        #expect(scope?.isNarrowed == true)
    }

    @Test("track rows map with per-row safety facts and keep order")
    func rowsMap() {
        let projection = makeProjection()
        let albumID = projection.artists[0].albums[0].id
        let rows = ActivitySnapshotAdapter.makeBrowseRows(BrowseBuilder.trackRows(
            forAlbumID: albumID,
            input: BrowseInput(
                tracks: [
                    Track(
                        id: "t1",
                        name: "The Regulator",
                        artist: "Clutch",
                        album: "Blast Tyrant",
                        genre: "Rock",
                        year: 2004,
                        originalPosition: 2,
                        appleScriptID: "as-1"
                    ),
                    Track(
                        id: "t2",
                        name: "Profits of Doom",
                        artist: "Clutch feat. Guest",
                        album: "Blast Tyrant",
                        originalPosition: 1,
                        appleScriptID: nil
                    ),
                ],
                scope: ProcessingScopeSnapshot.capture(
                    requestedTestArtists: ["Clutch"],
                    knownTrackCount: 2,
                    createdAt: Date(timeIntervalSince1970: 100),
                    reason: "adapter-test"
                ),
                physicalTrackCount: nil,
                readSource: .liveLibrary(scannedAt: Date(timeIntervalSince1970: 100)),
                previewUnavailableReason: nil
            )
        ))

        #expect(rows.map(\.title) == ["Profits of Doom", "The Regulator"])
        #expect(rows[0].hasWriteIdentity == false)
        #expect(rows[0].isInScope == false)
        #expect(rows[1].hasWriteIdentity == true)
        #expect(rows[1].isInScope == true)
    }

    @Test("an empty projection maps to an empty browse surface")
    func emptyProjectionMapsEmpty() {
        let empty = BrowseProjection.empty()

        #expect(ActivitySnapshotAdapter.makeBrowseArtists(from: empty).isEmpty)
        #expect(ActivitySnapshotAdapter.makeBrowseScope(from: empty) == nil)
    }
}
