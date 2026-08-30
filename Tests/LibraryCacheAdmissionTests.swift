import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Library cache admission")
@MainActor
struct LibraryCacheAdmissionTests {
    @Test("Recovered membership replaces stale presentation without gaining write authority")
    func prefersRecoveredMirror() async throws {
        let fixture = try makeFixture(testArtists: ["In Flames"], runRecordStore: RunRecordStoreStub())
        let cachedTracks = (0 ..< 403).map { index in
            canonicalMirrorTrack(Core.Track(
                id: "cached-\(index)",
                name: "Cached Track \(index)",
                artist: "In Flames",
                album: "Clayman"
            ))
        }
        let recoveredTracks = (0 ..< 201).map { index in
            canonicalMirrorTrack(Core.Track(
                id: "database-\(index)",
                name: "Library Track \(index)",
                artist: "In Flames",
                album: "Clayman"
            ))
        }
        await fixture.snapshotService.installSnapshot(cachedTracks)
        fixture.dependencies.configureLibraryPersistenceForTesting(
            trackStore: MirrorTrackStoreStub(tracks: recoveredTracks),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        var presentedCounts: [Int] = []
        fixture.dependencies.onLibraryLoadApplied = { presentedCounts.append($0.count) }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.count == 201)
        #expect(!fixture.dependencies.isLibraryReadyForUpdates)
        #expect(presentedCounts == [201])
        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
        #expect(try await fixture.snapshotService.loadSnapshot()?.count == 403)
    }

    @Test("Canonical membership replaces a broader cache without gaining write authority")
    func unreadyMirrorReplacesCache() async throws {
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
                certifiedArtists: ["Metallica"]
            ),
            librarySnapshotService: fixture.snapshotService,
            runRecordStore: RunRecordStoreStub()
        )
        var browsedTrackIDs: [[String]] = []
        fixture.dependencies.applyBrowseTruth = { processing, _ in
            browsedTrackIDs.append(processing.tracks.map(\.id))
        }
        var appliedTrackIDs: [[String]] = []
        fixture.dependencies.onLibraryLoadApplied = { tracks in
            appliedTrackIDs.append(tracks.map(\.id))
        }

        await fixture.dependencies.loadLibrary()

        #expect(fixture.dependencies.libraryTracks.map(\.id) == [partialTrack.id])
        #expect(!fixture.dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs == [[partialTrack.id]])
        #expect(appliedTrackIDs == [[partialTrack.id]])
        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
        #expect(try await fixture.snapshotService.loadSnapshot()?.map(\.id) == [cachedTrack.id])
    }

    @Test("An unknown recovered mirror is presented without creating a durable snapshot")
    func showsUnverifiedMirror() async throws {
        let snapshotService = SnapshotServiceSpy()
        let partialStore = MirrorTrackStoreStub(tracks: [canonicalMirrorTrack(Core.Track(
            id: "partial",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        ))])
        let dependencies = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        var browsedTrackIDs: [[String]] = []
        dependencies.applyBrowseTruth = { processing, _ in
            browsedTrackIDs.append(processing.tracks.map(\.id))
        }

        await dependencies.loadLibrary()

        let relaunched = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        await relaunched.loadLibrary()

        #expect(dependencies.libraryTracks.map(\.id) == ["partial"])
        #expect(relaunched.libraryTracks.map(\.id) == ["partial"])
        #expect(!dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs == [["partial"]])
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
        dependencies.applyBrowseTruth = { processing, _ in
            browsedTrackIDs.append(processing.tracks.map(\.id))
        }

        await dependencies.loadLibrary()

        let relaunched = makeLibraryDependencies(trackStore: partialStore, snapshotService: snapshotService)
        await relaunched.loadLibrary()

        #expect(dependencies.libraryTracks.map(\.id) == ["partial"])
        #expect(relaunched.libraryTracks.map(\.id) == ["partial"])
        #expect(!dependencies.isLibraryReadyForUpdates)
        #expect(browsedTrackIDs == [["partial"]])
        #expect(await snapshotService.savedSnapshotCount() == 0)
        #expect(try await snapshotService.loadSnapshot()?.isEmpty == true)
    }
}
