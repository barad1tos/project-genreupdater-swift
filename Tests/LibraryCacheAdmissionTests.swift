import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Library cache admission")
@MainActor
struct LibraryCacheAdmissionTests {
    @Test("A populated unready mirror keeps a broader cached library visible")
    func unreadyMirrorKeepsCache() async throws {
        let fixture = try makeFixture(testArtists: [], runRecordStore: RunRecordStoreStub())
        let cachedTrack = canonicalMirrorTrack(sampleTrack())
        let partialTrack = canonicalMirrorTrack(Core.Track(
            id: "partial",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        ))
        await fixture.snapshotService.installSnapshot([cachedTrack])
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(
                tracks: [partialTrack],
                coverage: .verified(MirrorScope(testArtists: ["Metallica"]))
            ),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        var browsedTrackIDs: [[String]] = []
        fixture.dependencies.applyBrowseTruthForLoad = { tracks, _, _ in
            browsedTrackIDs.append(tracks.map(\.id))
        }
        var appliedTrackIDs: [[String]] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            appliedTrackIDs.append(tracks.map(\.id))
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.map(\.id) == [cachedTrack.id])
        #expect(!fixture.dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs == [[cachedTrack.id]])
        #expect(appliedTrackIDs == [[cachedTrack.id]])
        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
        #expect(try await fixture.snapshotService.loadSnapshot()?.map(\.id) == [cachedTrack.id])
    }

    @Test("An unready mirror cannot create a snapshot when no cache exists")
    func missingCacheStaysEmpty() async throws {
        let snapshotService = SnapshotServiceSpy()
        let partialStore = MirrorTrackStoreStub(tracks: [canonicalMirrorTrack(Core.Track(
            id: "partial",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        ))])
        let dependencies = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        var browsedTrackIDs: [[String]] = []
        dependencies.applyBrowseTruthForLoad = { tracks, _, _ in
            browsedTrackIDs.append(tracks.map(\.id))
        }

        await dependencies.loadLibrary()

        let relaunched = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        await relaunched.loadLibrary()

        #expect(dependencies.libraryTracks.isEmpty)
        #expect(relaunched.libraryTracks.isEmpty)
        #expect(!dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs.isEmpty)
        #expect(await snapshotService.savedSnapshotCount() == 0)
        #expect(try await snapshotService.loadSnapshot() == nil)
    }

    @Test("A valid empty cache stays empty across a relaunch-like load")
    func emptyCachePersists() async throws {
        let snapshotService = SnapshotServiceSpy()
        await snapshotService.installSnapshot([])
        let partialStore = MirrorTrackStoreStub(tracks: [canonicalMirrorTrack(Core.Track(
            id: "partial",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        ))])
        let dependencies = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        var browsedTrackIDs: [[String]] = []
        dependencies.applyBrowseTruthForLoad = { tracks, _, _ in
            browsedTrackIDs.append(tracks.map(\.id))
        }

        await dependencies.loadLibrary()

        let relaunched = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        await relaunched.loadLibrary()

        #expect(dependencies.libraryTracks.isEmpty)
        #expect(relaunched.libraryTracks.isEmpty)
        #expect(!dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs == [[]])
        #expect(await snapshotService.savedSnapshotCount() == 0)
        #expect(try await snapshotService.loadSnapshot()?.isEmpty == true)
    }
}
