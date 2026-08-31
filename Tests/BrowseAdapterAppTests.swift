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
        let tracks = adapterTracks()
        let catalogTracks = tracks.map(makeAdapterCatalogTrack) + (2 ..< 40).map { index in
            makeAdapterCatalogTrack(Track(
                id: "catalog-\(index)",
                name: "Catalog \(index)",
                artist: "Other",
                album: "Other"
            ))
        }
        return BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: tracks,
            catalogTracks: catalogTracks,
            testArtists: ["Clutch"]
        ))
    }

    @Test("browse nodes map field-for-field onto the design vocabulary")
    func nodesMapFieldForField() {
        let projection = makeProjection()

        let artists = ActivitySnapshotAdapter.makeBrowseArtists(from: projection)

        #expect(artists.count == 2)
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
        let tracks = [Track(id: "t", name: "Song", artist: "Other", album: "Elsewhere")]
        let projection = BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: tracks,
            testArtists: ["Clutch"]
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

    @Test("catalog fallback issues map onto the visible browse notice")
    func catalogIssueMapsToNotice() {
        let projection = BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: adapterTracks(),
            testArtists: ["Clutch"],
            catalogIssue: "MusicKit fetch failed"
        ))

        let notice = ActivitySnapshotAdapter.makeBrowseNotice(from: projection)

        #expect(notice == "The Music catalog may be out of date. Refresh the library to retry the Music catalog read.")
    }

    @Test("a command outcome outranks the background catalog notice")
    func commandOutcomeOutranksCatalogNotice() {
        let projection = BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: adapterTracks(),
            testArtists: ["Clutch"],
            catalogIssue: "MusicKit fetch failed"
        ))
        let commandNotice = BrowseCommandNotice(
            message: "The album preview is unavailable.",
            projectionRevision: projection.revision
        )

        let notice = ActivitySnapshotAdapter.makeBrowseNotice(
            from: projection,
            commandNotice: commandNotice
        )

        #expect(notice == "The album preview is unavailable.")
    }

    @Test("a newer projection expires the previous command outcome")
    func newerProjectionExpiresCommandOutcome() {
        let projection = BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: adapterTracks(),
            testArtists: ["Clutch"],
            catalogIssue: "MusicKit fetch failed"
        ))
        let commandNotice = BrowseCommandNotice(
            message: "The album preview is unavailable.",
            projectionRevision: projection.revision
        )
        let refreshedProjection = advanceProjection(projection)

        let notice = ActivitySnapshotAdapter.makeBrowseNotice(
            from: refreshedProjection,
            commandNotice: commandNotice
        )

        #expect(notice == "The Music catalog may be out of date. Refresh the library to retry the Music catalog read.")
    }

    @Test("an outcome racing a warning refresh stays bound to its command target")
    func warningRefreshKeepsTargetRevision() {
        let projection = BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: adapterTracks(),
            testArtists: ["Clutch"],
            catalogIssue: "MusicKit fetch failed"
        ))
        let refreshedProjection = advanceProjection(projection)
        let notice = BrowseCommandNotice.makeOutcome(
            message: "Preview services are unavailable.",
            status: .temporaryUnavailable,
            targetRevision: .initial,
            currentProjection: refreshedProjection
        )

        #expect(notice.projectionRevision == .initial)
    }

    @Test("an outcome racing a clean refresh remains visible on the refreshed projection")
    func cleanRefreshUsesCurrentRevision() {
        let projection = BrowseBuilder.makeProjection(input: makeAdapterBrowseInput(
            tracks: adapterTracks(),
            testArtists: ["Clutch"]
        ))
        let refreshedProjection = advanceProjection(projection)
        let notice = BrowseCommandNotice.makeOutcome(
            message: "Preview services are unavailable.",
            status: .temporaryUnavailable,
            targetRevision: .initial,
            currentProjection: refreshedProjection
        )

        #expect(notice.projectionRevision == refreshedProjection.revision)
    }

    @Test("a rejection that republishes Browse belongs to the refreshed projection")
    func rejectionUsesCurrentRevision() {
        let currentRevision = ProjectionRevision.initial.advanced()
        let currentProjection = BrowseProjection.empty(revision: currentRevision)
        let notice = BrowseCommandNotice.makeOutcome(
            message: "Browse just refreshed.",
            status: .rejectedStale,
            targetRevision: .initial,
            currentProjection: currentProjection
        )

        #expect(notice.projectionRevision == currentRevision)
    }

    @Test("track rows map with per-row safety facts and keep order")
    func rowsMap() {
        let projection = makeProjection()
        let albumID = projection.artists[0].albums[0].id
        let rows = ActivitySnapshotAdapter.makeBrowseRows(BrowseBuilder.trackRows(
            forAlbumID: albumID,
            input: makeAdapterBrowseInput(tracks: adapterTracks(), testArtists: ["Clutch"])
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

    private func advanceProjection(_ projection: BrowseProjection) -> BrowseProjection {
        BrowseProjection(
            revision: projection.revision.advanced(),
            artists: projection.artists,
            scope: projection.scope,
            physicalTrackCount: projection.physicalTrackCount,
            readSource: projection.readSource,
            operationalIssues: projection.operationalIssues
        )
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
        installAdapterCatalog([track], on: dependencies)

        let firstInput = dependencies.makeBrowseInput(processing: makeAdapterProcessingFacts([track], on: dependencies))
        let firstGeneration = await dependencies.claimBrowseInputGeneration()
        let first = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: firstInput),
            inputGeneration: firstGeneration
        )
        let secondInput = dependencies.makeBrowseInput(processing: makeAdapterProcessingFacts(
            [track],
            on: dependencies
        ))
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

        let newerTrack = Track(id: "new", name: "New", artist: "Clutch", album: "Newer")
        installAdapterCatalog([newerTrack], on: dependencies)
        let newerInput = dependencies.makeBrowseInput(
            processing: makeAdapterProcessingFacts([newerTrack], on: dependencies)
        )
        _ = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: newerInput),
            inputGeneration: newerGeneration
        )

        let olderTrack = Track(id: "old", name: "Old", artist: "Clutch", album: "Older")
        installAdapterCatalog([olderTrack], on: dependencies)
        let olderInput = dependencies.makeBrowseInput(
            processing: makeAdapterProcessingFacts([olderTrack], on: dependencies)
        )
        let result = await dependencies.publishBrowseProjection(
            BrowseBuilder.makeProjection(input: olderInput),
            inputGeneration: olderGeneration
        )

        // The slow older claimant is dropped even though it finished last.
        #expect(result.artists.first?.albums.first?.title == "Newer")
        #expect(await dependencies.projectionStore.currentBrowse().artists.first?.albums.first?.title == "Newer")
    }

    @Test("the browse commands factory routes alias matches to the canonical preview target")
    func factoryUsesCanonicalTarget() async throws {
        let dependencies = makeDependencies()
        dependencies.config.development.testArtists = ["Guest Artist"]
        let recorder = ProducedTargetRecorder()
        dependencies.installTrackCountSource { 1 }
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { scope in SyncResult().committed(to: scope) },
            synchronizePreview: { scope, _, _ in SyncResult().committed(to: scope) },
            persistRunRecord: { _ in
                // Persistence is outside this wiring pin.
            },
            produceFixPlan: { _, _, configuration in
                recorder.record(configuration.albumTarget)
                return .empty
            }
        )))

        let processingTrack = Track(
            id: "t",
            name: "Song",
            artist: "Guest Artist",
            album: "Compilation",
            albumArtist: "Various Artists",
            appleScriptID: "as-1"
        )
        let catalogTrack = Track(
            id: "t",
            name: "Song",
            artist: "Guest Artist",
            album: "Compilation",
            appleScriptID: "as-1"
        )
        installAdapterCatalog([catalogTrack], on: dependencies)
        let input = dependencies.makeBrowseInput(
            processing: makeAdapterProcessingFacts([processingTrack], on: dependencies)
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
        #expect(recorder.target == FixPlanAlbumTarget(artist: "Various Artists", album: "Compilation"))
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

private func adapterTracks() -> [Track] {
    [
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
    ]
}

private func makeAdapterBrowseInput(
    tracks: [Track],
    catalogTracks: [CatalogTrack]? = nil,
    testArtists: [String],
    catalogIssue: String? = nil
) -> BrowseInput {
    BrowseInput(
        catalog: BrowseCatalogFacts(
            snapshot: CatalogSnapshot(
                tracks: catalogTracks ?? tracks.map(makeAdapterCatalogTrack),
                capturedAt: Date(timeIntervalSince1970: 100)
            ),
            source: .live,
            issue: catalogIssue.map(CatalogIssue.refreshFailed(message:))
        ),
        processing: BrowseProcessingFacts(
            tracks: tracks,
            readiness: adapterReadyReadiness(testArtists: testArtists, trackCount: tracks.count)
        ),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: testArtists,
            knownTrackCount: tracks.count,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "adapter-test"
        ),
        previewUnavailableReason: nil
    )
}

private func makeAdapterCatalogTrack(_ track: Track) -> CatalogTrack {
    guard let id = CatalogTrackID(displayValue: track.id) else {
        preconditionFailure("Adapter fixture catalog IDs must be non-empty")
    }
    return CatalogTrack(
        id: id,
        title: track.name,
        artist: track.artist,
        album: track.album,
        albumArtist: track.albumArtist,
        genres: track.genre.map { [$0] } ?? [],
        dates: CatalogDates(releaseYear: track.year, dateAdded: track.dateAdded)
    )
}

@MainActor
private func makeAdapterProcessingFacts(
    _ tracks: [Track],
    on dependencies: AppDependencies
) -> BrowseProcessingFacts {
    BrowseProcessingFacts(tracks: tracks, readiness: dependencies.libraryReadiness)
}

@MainActor
private func installAdapterCatalog(_ tracks: [Track], on dependencies: AppDependencies) {
    dependencies.catalogSnapshot = CatalogSnapshot(tracks: tracks.map(makeAdapterCatalogTrack))
    dependencies.catalogSnapshotSource = .live
    dependencies.libraryReadiness = adapterReadyReadiness(
        testArtists: dependencies.config.development.testArtists,
        trackCount: tracks.count
    )
}

private func adapterReadyReadiness(testArtists: [String], trackCount: Int) -> MirrorReadiness {
    guard let membership = try? MembershipStamp(fingerprint: String(repeating: "b", count: 64)) else {
        preconditionFailure("Adapter fixture membership fingerprint must be canonical")
    }
    return .ready(ScopeCertificate(
        id: UUID(),
        revision: .initial,
        membership: membership,
        testArtists: testArtists,
        fieldSet: .processingV1,
        evidence: ScopeEvidence(
            requestedFingerprint: "adapter-fixture",
            observedFingerprint: "adapter-fixture",
            trackCount: trackCount
        ),
        observedAt: Date(timeIntervalSince1970: 100)
    ))
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
