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
            readSource: .cachedMirror(scannedAt: Date(timeIntervalSince1970: 100)),
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
            readSource: .cachedMirror(scannedAt: Date(timeIntervalSince1970: 100)),
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
                readSource: .cachedMirror(scannedAt: Date(timeIntervalSince1970: 100)),
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

@Suite("Browse host publish")
@MainActor
struct BrowseHostPublishTests {
    private func makeDependencies() -> AppDependencies {
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // Persistence is irrelevant to these pins.
            }
        )
        dependencies.config.development.testArtists = ["Clutch"]
        return dependencies
    }

    @Test("the browse scope snapshot is stable until Test Artists change")
    func scopeSnapshotStability() {
        let dependencies = makeDependencies()

        let first = dependencies.currentBrowseScopeSnapshot()
        let second = dependencies.currentBrowseScopeSnapshot()
        #expect(second.id == first.id)

        dependencies.config.development.testArtists = ["Clutch", "Anthrax"]
        let recaptured = dependencies.currentBrowseScopeSnapshot()
        #expect(recaptured.id != first.id)
        #expect(recaptured.normalizedTestArtists == ["Clutch", "Anthrax"])
    }

    @Test("noise variants hold the snapshot; reorder recaptures")
    func scopeSnapshotCacheKeyVariants() {
        let dependencies = makeDependencies()
        let first = dependencies.currentBrowseScopeSnapshot()

        // A case-duplicate normalizes away — same membership, same snapshot.
        dependencies.config.development.testArtists = ["Clutch", "clutch"]
        #expect(dependencies.currentBrowseScopeSnapshot().id == first.id)

        // Reorder changes the normalized list (order is preserved), so the
        // snapshot recaptures — detail labels join in order.
        dependencies.config.development.testArtists = ["Anthrax", "Clutch"]
        dependencies.config.development.testArtists = ["Clutch", "Anthrax"]
        let reordered = dependencies.currentBrowseScopeSnapshot()
        dependencies.config.development.testArtists = ["Anthrax", "Clutch"]
        #expect(dependencies.currentBrowseScopeSnapshot().id != reordered.id)
    }

    @Test("publishing identical browse input keeps the revision")
    func identicalPublishDedups() async {
        let dependencies = makeDependencies()
        let track = Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")

        let firstInput = await dependencies.makeBrowseInput(
            tracks: [track],
            readSource: .cachedMirror(scannedAt: nil)
        )
        let firstGeneration = await dependencies.claimBrowseInputGeneration()
        let first = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: firstInput),
            inputGeneration: firstGeneration
        )
        let secondInput = await dependencies.makeBrowseInput(
            tracks: [track],
            readSource: .cachedMirror(scannedAt: nil)
        )
        let secondGeneration = await dependencies.claimBrowseInputGeneration()
        let second = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: secondInput),
            inputGeneration: secondGeneration
        )

        #expect(first.artists.count == 1)
        #expect(second.revision == first.revision)
        #expect(await dependencies.projectionStore.currentBrowse() == second)
    }

    @Test("an early-claimed older generation loses to a newer publish")
    func staleClaimantLoses() async {
        let dependencies = makeDependencies()
        let olderGeneration = await dependencies.claimBrowseInputGeneration()
        let newerGeneration = await dependencies.claimBrowseInputGeneration()

        let newerInput = await dependencies.makeBrowseInput(
            tracks: [Track(id: "new", name: "New", artist: "Clutch", album: "Newer")],
            readSource: .cachedMirror(scannedAt: nil)
        )
        _ = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: newerInput),
            inputGeneration: newerGeneration
        )

        let olderInput = await dependencies.makeBrowseInput(
            tracks: [Track(id: "old", name: "Old", artist: "Clutch", album: "Older")],
            readSource: .cachedMirror(scannedAt: nil)
        )
        let result = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: olderInput),
            inputGeneration: olderGeneration
        )

        // The slow older claimant is dropped even though it finished last.
        #expect(result.artists.first?.albums.first?.title == "Newer")
        #expect(await dependencies.projectionStore.currentBrowse().artists.first?.albums.first?.title == "Newer")
    }

    @Test("the browse commands factory routes into preview production only")
    func factoryRoutesToPreview() async throws {
        let dependencies = makeDependencies()
        let recorder = ProducedTargetRecorder()
        dependencies.installTrackCountSource { 1 }
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            synchronizePreview: { scope, _ in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this wiring pin.
            },
            produceFixPlan: { _, _, configuration in
                recorder.record(configuration.albumTarget)
                return .empty
            }
        )))

        let input = await dependencies.makeBrowseInput(
            tracks: [Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant", appleScriptID: "as-1")],
            readSource: .cachedMirror(scannedAt: nil)
        )
        let generation = await dependencies.claimBrowseInputGeneration()
        let published = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: input),
            inputGeneration: generation
        )
        let album = try #require(published.artists.first?.albums.first)
        let scopeID = try #require(published.scope?.snapshotID)

        let commands = dependencies.makeBrowseCommands {
            // Republish is host-owned; irrelevant to the routing pin.
        }
        let status = await commands.performAlbumPreview(target: BrowseCommandTarget(
            albumID: album.id,
            projectionRevision: published.revision,
            scopeSnapshotID: scopeID
        ))

        // The dispatch reached fix-plan production — the preview-only
        // seam — carrying the album target; no write seam exists here.
        #expect(status == .noOp)
        #expect(recorder.target == FixPlanAlbumTarget(artist: "Clutch", album: "Blast Tyrant"))
    }

    @Test("makeSnapshot carries browse truth through")
    func makeSnapshotCarriesBrowse() {
        let artist = DesignUI.Artist(id: "a", name: "Clutch", albums: [])
        let scope = DesignBrowseScope(sourceLabel: "Test artists (1)", detailLabel: "Clutch", isNarrowed: true)

        let snapshot = ActivitySnapshotAdapter.makeSnapshot(
            from: DesignActivitySnapshotInput(
                library: .empty,
                workflow: .empty,
                settings: .preview,
                now: Date(timeIntervalSince1970: 100)
            ),
            activityProjection: .empty(),
            browse: ActivitySnapshotAdapter.BrowseSnapshotInput(artists: [artist], scope: scope)
        )

        #expect(snapshot.artists == [artist])
        #expect(snapshot.browseScope == scope)
    }
}

private final class ProducedTargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FixPlanAlbumTarget?

    var target: FixPlanAlbumTarget? {
        lock.withLock { value }
    }

    func record(_ target: FixPlanAlbumTarget?) {
        lock.withLock { value = target }
    }
}
