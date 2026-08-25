import Core
import Foundation
import Testing
@testable import Services

@Suite("Music.app observation")
struct MusicAppObservationTests {
    @Test("Fast observation fetches only IDs absent from the previous mirror")
    func fetchesOnlyNewMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let firstTrack = track(id: firstID, artist: "Existing Artist")
        let secondTrack = track(id: secondID, artist: "New Artist")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [secondID: secondTrack]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(
            tracksByID: [firstID: firstTrack]
        ))

        let observation = try await reader.observe(request(
            refresh: .fast,
            previous: .verified(mirror)
        ))

        #expect(await source.metadataRequests == [[secondID]])
        #expect(observation.currentIDs == [firstID, secondID])
        #expect(observation.tracks.map(\.databaseID) == [secondID])
        #expect(observation.membership == .full)
        #expect(observation.metadata.requestedIDs == [secondID])
        #expect(observation.metadata.observedIDs == [secondID])
    }

    @Test("Forced observation refreshes common IDs through the configured source")
    func refreshesCommonMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let firstTrack = track(id: firstID, artist: "Existing Artist")
        let secondTrack = track(id: secondID, artist: "New Artist")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [firstID: firstTrack, secondID: secondTrack]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(
            tracksByID: [firstID: firstTrack]
        ))

        let observation = try await reader.observe(request(
            refresh: .force,
            previous: .verified(mirror)
        ))

        #expect(await source.metadataRequests == [[firstID, secondID]])
        #expect(observation.tracks.map(\.databaseID) == [firstID, secondID])
        #expect(observation.metadata.isComplete)
    }

    @Test("Membership-only observation fences IDs without fetching metadata")
    func observesMembershipWithoutMetadata() async throws {
        let retainedID = try databaseID("1")
        let removedID = try databaseID("2")
        let newID = try databaseID("3")
        let generation = try libraryGeneration("G1")
        let retainedTrack = track(id: retainedID, artist: "Target")
        let removedTrack = track(id: removedID, artist: "Target")
        let source = try ObservationSourceStub(
            censuses: [census([retainedID, newID], generation: generation)],
            tracks: [newID: track(id: newID, artist: "Target")]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(tracksByID: [
            retainedID: retainedTrack,
            removedID: removedTrack,
        ]))

        let observation = try await reader.observe(request(
            artists: ["Target"],
            refresh: .membershipOnly,
            previous: .verified(mirror)
        ))

        #expect(await source.metadataRequests.isEmpty)
        #expect(observation.currentIDs == [retainedID])
        #expect(observation.tracks.isEmpty)
        #expect(observation.membership == .scoped(unobservedIDs: [newID]))
        #expect(observation.metadata.requestedIDs.isEmpty)
        #expect(observation.metadata.observedIDs.isEmpty)
    }

    @Test("Partial metadata keeps complete membership and reports unobserved rows")
    func reportsPartialMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [firstID: track(id: firstID, artist: "Observed Artist")]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request())

        #expect(observation.currentIDs == [firstID, secondID])
        #expect(observation.membership == .full)
        #expect(observation.metadata.requestedIDs == [firstID, secondID])
        #expect(observation.metadata.observedIDs == [firstID])
        #expect(!observation.metadata.isComplete)
        #expect(observation.issues == [
            .metadataUnobserved(databaseID: secondID, detail: "Metadata lookup returned no row"),
        ])
    }

    @Test("Artist scope prefers album artist and falls back only when it is absent")
    func appliesEffectiveArtistScope() async throws {
        let albumArtistID = try databaseID("1")
        let fallbackID = try databaseID("2")
        let excludedID = try databaseID("3")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([albumArtistID, fallbackID, excludedID], generation: generation)],
            tracks: [
                albumArtistID: track(id: albumArtistID, artist: "Other", albumArtist: "Target"),
                fallbackID: track(id: fallbackID, artist: "Target", albumArtist: nil),
                excludedID: track(id: excludedID, artist: "Target", albumArtist: "Other"),
            ]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request(artists: ["Target"]))

        #expect(observation.currentIDs == [albumArtistID, fallbackID])
        #expect(observation.tracks.map(\.databaseID) == [albumArtistID, fallbackID])
        #expect(observation.membership == .scoped(unobservedIDs: []))
        #expect(observation.tracks[1].albumArtist == .absent)
    }

    @Test("Scoped service accepts full-census metadata from the real observer")
    func scopedServiceAcceptsObserverCompleteness() async throws {
        let targetID = try databaseID("1")
        let outsideID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([targetID, outsideID], generation: generation)],
            tracks: [
                targetID: track(id: targetID, artist: "Target"),
                outsideID: track(id: outsideID, artist: "Other"),
            ]
        )
        let observer = MusicAppObserver(source: source)
        let store = SyncMockTrackStore()
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Target"]),
            observer: observer
        )

        let result = try await service.detectObservation().result

        #expect(await source.metadataRequests == [[targetID, outsideID]])
        #expect(result.newTracks.map(\.id) == ["1"])
    }

    @Test("Scoped force sync preserves a census-present row that exits its artist scope")
    func scopedSyncPreservesScopeExit() async throws {
        let databaseID = try databaseID("1")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([databaseID], generation: generation)],
            tracks: [databaseID: track(id: databaseID, artist: "Other")]
        )
        let observer = MusicAppObserver(source: source)
        let store = SyncMockTrackStore()
        await store.setStored([Track(
            id: "1",
            name: "Song 1",
            artist: "Target",
            album: "Album",
            appleScriptID: "1"
        )])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Target"]),
            observer: observer
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(await source.metadataRequests == [[databaseID]])
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await store.storedTracks.map(\.id) == ["1"])
    }

    @Test("Stable empty census is a valid full observation")
    func acceptsStableEmptyCensus() async throws {
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([], generation: generation)],
            tracks: [:]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request())

        #expect(observation.currentIDs.isEmpty)
        #expect(observation.tracks.isEmpty)
        #expect(observation.membership == .full)
        #expect(observation.metadata.isComplete)
        #expect(await source.metadataRequests.isEmpty)
    }

    @Test("Generation change after metadata prevents an observation result")
    func rejectsGenerationChange() async throws {
        let databaseID = try databaseID("1")
        let firstGeneration = try libraryGeneration("G1")
        let secondGeneration = try libraryGeneration("G2")
        let source = try ObservationSourceStub(
            censuses: [
                census([databaseID], generation: firstGeneration),
                census([databaseID], generation: secondGeneration),
            ],
            tracks: [databaseID: track(id: databaseID, artist: "Artist")]
        )
        let reader = MusicAppObserver(source: source)

        do {
            _ = try await reader.observe(request())
            Issue.record("Expected generation change to reject the observation")
        } catch let MusicAppObservationError.generationChanged(started, ended) {
            #expect(started == firstGeneration)
            #expect(ended == secondGeneration)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Census failure is not converted into an empty observation")
    func preservesCensusFailure() async throws {
        let source = ObservationSourceStub(censusError: ObservationTestError.censusFailed)
        let reader = MusicAppObserver(source: source)

        await #expect(throws: ObservationTestError.censusFailed) {
            _ = try await reader.observe(request())
        }
        #expect(await source.metadataRequests.isEmpty)
    }

    private func request(
        artists: [String] = [],
        refresh: MetadataRefreshPolicy = .fast,
        previous: LibraryMirrorReference = .initial
    ) -> LibraryObservationRequest {
        LibraryObservationRequest(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: artists,
                knownTrackCount: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                reason: "observation fixture"
            ),
            refresh: refresh,
            previous: previous
        )
    }

    private func track(
        id: MusicDatabaseTrackID,
        artist: String,
        albumArtist: String? = nil
    ) -> Track {
        Track(
            id: "source-\(id.rawValue)",
            name: "Song \(id.rawValue)",
            artist: artist,
            album: "Album",
            genre: nil,
            year: 2001,
            dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
            lastModified: Date(timeIntervalSince1970: 1_650_000_000),
            trackStatus: nil,
            releaseYear: 2000,
            albumArtist: albumArtist,
            appleScriptID: id.rawValue
        )
    }

    private func databaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: rawValue))
    }

    private func libraryGeneration(_ rawValue: String) throws -> LibraryGeneration {
        try #require(LibraryGeneration(sourceValue: rawValue))
    }

    private func census(
        _ ids: [MusicDatabaseTrackID],
        generation: LibraryGeneration
    ) throws -> TrackIDCensus {
        try TrackIDCensus(ids: ids, totalCount: ids.count, generation: generation)
    }
}

private enum ObservationTestError: Error, Equatable {
    case censusFailed
}

private actor ObservationSourceStub: ObservationSource {
    private var censuses: [TrackIDCensus]
    private let tracks: [MusicDatabaseTrackID: Track]
    private let censusError: ObservationTestError?
    private(set) var metadataRequests: [[MusicDatabaseTrackID]] = []

    init(
        censuses: [TrackIDCensus] = [],
        tracks: [MusicDatabaseTrackID: Track] = [:],
        censusError: ObservationTestError? = nil
    ) {
        self.censuses = censuses
        self.tracks = tracks
        self.censusError = censusError
    }

    func fetchCensus() throws -> TrackIDCensus {
        if let censusError {
            throw censusError
        }
        guard !censuses.isEmpty else {
            throw ObservationTestError.censusFailed
        }
        if censuses.count == 1 {
            return censuses[0]
        }
        return censuses.removeFirst()
    }

    func fetchMetadata(for ids: [MusicDatabaseTrackID]) -> [Track] {
        metadataRequests.append(ids)
        return ids.compactMap { tracks[$0] }
    }
}
