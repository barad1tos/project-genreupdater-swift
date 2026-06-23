import Foundation
import Testing
@testable import Core
@testable import Services

private struct PendingCoordinatorFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private func makePendingCoordinator(
    year: Int?,
    confidence: Int,
    runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration()
) async -> PendingCoordinatorFixture {
    let yearScores: [Int: Int] = if let year {
        [year: confidence]
    } else {
        [:]
    }
    let yearResult = YearResult(
        year: year,
        confidence: confidence,
        yearScores: yearScores
    )
    let apiService = MockAPIService(yearResult: yearResult)
    return await makePendingCoordinator(apiService: apiService, runtimeConfiguration: runtimeConfiguration)
}

private func makePendingCoordinator(
    apiService: any ExternalAPIService,
    runtimeConfiguration: UpdateRuntimeConfiguration = UpdateRuntimeConfiguration(),
    pendingVerification: RecordingPendingVerificationService? = nil,
    reachability: NetworkReachabilityMonitor? = nil
) async -> PendingCoordinatorFixture {
    let bridge = MockAppleScriptClient()
    let store = MockTrackStore()
    let cache = MockCacheService()
    let undoDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCoordinatorPendingTests-\(UUID().uuidString)")
    let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDir)
    let orchestrator = makeAPIOrchestrator(
        musicBrainz: apiService,
        discogs: apiService,
        appleMusic: apiService
    ) { configuration in
        configuration.pendingVerificationService = pendingVerification
        configuration.reachability = reachability
    }
    let coordinator = UpdateCoordinator(
        dependencies: UpdateCoordinatorDependencies(
            apiOrchestrator: orchestrator,
            scriptBridge: bridge,
            trackStore: store,
            cache: cache,
            undoCoordinator: undo,
            pendingVerificationService: pendingVerification
        ),
        genreDeterminator: GenreDeterminator(),
        runtimeConfiguration: runtimeConfiguration
    )
    return PendingCoordinatorFixture(
        coordinator: coordinator,
        bridge: bridge
    )
}

private func makePendingTrack(
    id: String,
    name: String = "Track",
    artist: String,
    album: String,
    year: Int?,
    albumArtist: String? = nil
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: album,
        year: year,
        albumArtist: albumArtist
    )
}

private struct PendingCanonicalAPIService: ExternalAPIService {
    let probe: APIRequestProbe
    let canonicalArtist: String
    let canonicalAlbum: String
    let year: Int

    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await probe.recordRequest(artist: artist, album: album)
        guard artist == canonicalArtist, album == canonicalAlbum else {
            return YearResult()
        }
        return YearResult(
            year: year,
            confidence: 100,
            yearScores: [year: 100]
        )
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

@Suite("UpdateCoordinator - pending verification")
struct PendingVerificationCoordinatorTests {
    @Test("Applies resolved API year to album tracks")
    func appliesResolvedYearToAlbumTracks() async throws {
        let fixture = await makePendingCoordinator(year: 1997, confidence: 55)
        let entry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "My Own Summer",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
            makePendingTrack(
                id: "T2",
                name: "Be Quiet and Drive",
                artist: "Deftones",
                album: "Around the Fur",
                year: 1998
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == 1997)
        #expect(result.entries.count == 2)
        #expect(written.count == 2)
        #expect(written.allSatisfy { $0.property == "year" && $0.value == "1997" })
    }

    @Test("No-op pending write does not create a change entry")
    func noOpPendingWriteDoesNotCreateChangeEntry() async throws {
        let fixture = await makePendingCoordinator(year: 1997, confidence: 100)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let entry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "My Own Summer",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == 1997)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(written.count == 1)
    }

    @Test("Test artist skip reports pending write unresolved")
    func artistSkipReportsPendingWriteUnresolved() async throws {
        let fixture = await makePendingCoordinator(
            year: 1997,
            confidence: 100,
            runtimeConfiguration: UpdateRuntimeConfiguration(testArtists: ["Other Artist"])
        )
        let entry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "My Own Summer",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == 1997)
        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs == ["T1"])
        #expect(result.errorDescriptions.first?.contains("outside test artist allow-list") == true)
        #expect(written.isEmpty)
    }

    @Test("Partial pending write reports success and failure without aborting")
    func partialPendingWriteReportsSuccessAndFailure() async throws {
        let fixture = await makePendingCoordinator(year: 1997, confidence: 100)
        await fixture.bridge.setFailingWriteTrackIDs(["T2"])
        let entry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "My Own Summer",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
            makePendingTrack(
                id: "T2",
                name: "Be Quiet and Drive",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == 1997)
        #expect(result.entries.map(\.trackID) == ["T1"])
        #expect(result.failedTrackIDs == ["T2"])
        #expect(result.errorDescriptions.isEmpty == false)
        #expect(written.map(\.trackID) == ["T1"])
    }

    @Test("Pending verification API lookup has no pending-store side effects")
    func pendingVerificationAPILookupHasNoPendingStoreSideEffects() async throws {
        let pendingVerification = RecordingPendingVerificationService()
        let fixture = await makePendingCoordinator(
            apiService: MockAPIService(
                yearResult: YearResult(
                    year: 1997,
                    confidence: 100,
                    yearScores: [1997: 100]
                )
            ),
            pendingVerification: pendingVerification
        )
        await fixture.bridge.setFailingWriteTrackIDs(["T1"])
        let entry = PendingAlbumEntry(
            id: "deftones-around-the-fur",
            artist: "Deftones",
            album: "Around the Fur",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "My Own Summer",
                artist: "Deftones",
                album: "Around the Fur",
                year: nil
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        #expect(result.resolvedYear == 1997)
        #expect(result.failedTrackIDs == ["T1"])
        #expect(await pendingVerification.removalCount() == 0)
        #expect(await pendingVerification.markCount() == 0)
    }

    @Test("Verifies legacy pending entry through resolved album identity artist")
    func verifiesLegacyPendingEntryThroughResolvedAlbumIdentityArtist() async throws {
        let apiProbe = APIRequestProbe()
        let fixture = await makePendingCoordinator(
            apiService: PendingCanonicalAPIService(
                probe: apiProbe,
                canonicalArtist: "Daft Punk",
                canonicalAlbum: "Random Access Memories",
                year: 2013
            )
        )
        let entry = PendingAlbumEntry(
            id: "daft-punk-feat-pharrell-williams-random-access-memories",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories",
                year: nil,
                albumArtist: "Daft Punk"
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let requests = await apiProbe.albumRequests
        #expect(requests.first?.artist == "Daft Punk")
        #expect(requests.first?.album == "Random Access Memories")
        #expect(result.resolvedYear == 2013)
        #expect(result.entries.map(\.trackID) == ["T1"])
    }

    @Test("Skips API lookup when pending entry does not match provided album tracks")
    func skipsAPILookupWhenPendingEntryDoesNotMatchProvidedAlbumTracks() async throws {
        let apiProbe = APIRequestProbe()
        let fixture = await makePendingCoordinator(
            apiService: PendingCanonicalAPIService(
                probe: apiProbe,
                canonicalArtist: "Daft Punk",
                canonicalAlbum: "Random Access Memories",
                year: 2013
            )
        )
        let entry = PendingAlbumEntry(
            id: "wrong-artist-wrong-album",
            artist: "Wrong Artist",
            album: "Wrong Album",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "Get Lucky",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: nil
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)
        let written = await fixture.bridge.writtenProperties

        #expect(result.resolvedYear == nil)
        #expect(result.entries.isEmpty)
        #expect(await apiProbe.requestCount == 0)
        #expect(written.isEmpty)
    }

    @Test("Skips API lookup when pending album tracks contain another album identity")
    func skipsAPILookupWhenPendingAlbumTracksContainAnotherAlbumIdentity() async throws {
        let apiProbe = APIRequestProbe()
        let fixture = await makePendingCoordinator(
            apiService: PendingCanonicalAPIService(
                probe: apiProbe,
                canonicalArtist: "Daft Punk",
                canonicalAlbum: "Random Access Memories",
                year: 2013
            )
        )
        let entry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                name: "Get Lucky",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: nil
            ),
            makePendingTrack(
                id: "T2",
                name: "American Sleep",
                artist: "Clutch",
                album: "Pure Rock Fury",
                year: nil
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)
        let written = await fixture.bridge.writtenProperties

        #expect(result.resolvedYear == nil)
        #expect(result.entries.isEmpty)
        #expect(await apiProbe.requestCount == 0)
        #expect(written.isEmpty)
    }

    @Test("Leaves album untouched when API has no year")
    func skipsWhenNoYearResolved() async throws {
        let pendingVerification = RecordingPendingVerificationService()
        let fixture = await makePendingCoordinator(
            apiService: MockAPIService(yearResult: YearResult()),
            pendingVerification: pendingVerification
        )
        let entry = PendingAlbumEntry(
            id: "unknown-album",
            artist: "Unknown",
            album: "Missing",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(id: "T1", artist: "Unknown", album: "Missing", year: nil),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let written = await fixture.bridge.writtenProperties
        #expect(result.resolvedYear == nil)
        #expect(result.entries.isEmpty)
        #expect(written.isEmpty)
        #expect(await pendingVerification.markCount() == 1)
        #expect(await pendingVerification.firstMark()?.artist == "Unknown")
        #expect(await pendingVerification.firstMark()?.album == "Missing")
    }

    @Test("Offline pending verification does not refresh retry state")
    func offlinePendingVerificationDoesNotRefreshRetryState() async throws {
        let apiProbe = APIRequestProbe()
        let pendingVerification = RecordingPendingVerificationService()
        let fixture = await makePendingCoordinator(
            apiService: UpdateCoordinatorRecordingAPIService(
                probe: apiProbe,
                yearResult: YearResult(
                    year: 2013,
                    confidence: 100,
                    yearScores: [2013: 100]
                )
            ),
            pendingVerification: pendingVerification,
            reachability: NetworkReachabilityMonitor(initialIsConnected: false)
        )
        let entry = PendingAlbumEntry(
            id: "daft-punk-random-access-memories",
            artist: "Daft Punk",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(id: "T1", artist: "Daft Punk", album: "Random Access Memories", year: nil),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        #expect(result.resolvedYear == nil)
        #expect(result.entries.isEmpty)
        #expect(await apiProbe.requestCount == 0)
        #expect(await pendingVerification.markCount() == 0)
    }

    @Test("No-year pending verification refreshes matching legacy aliases")
    func noYearPendingVerificationRefreshesMatchingLegacyAliases() async throws {
        let pendingVerification = RecordingPendingVerificationService(entries: [
            PendingAlbumEntry(
                id: "legacy-no-year",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
            PendingAlbumEntry(
                id: "canonical-no-year",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
            PendingAlbumEntry(
                id: "canonical-prerelease",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "prerelease"
            ),
        ])
        let fixture = await makePendingCoordinator(
            apiService: MockAPIService(yearResult: YearResult()),
            pendingVerification: pendingVerification
        )
        let entry = PendingAlbumEntry(
            id: "legacy-no-year",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories",
            reason: "no_year_found"
        )
        let albumTracks = [
            makePendingTrack(
                id: "T1",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                year: nil,
                albumArtist: "Daft Punk"
            ),
        ]

        let result = try await fixture.coordinator.verifyPendingAlbum(entry, albumTracks: albumTracks)

        let marks = await pendingVerification.allMarks()
        #expect(result.resolvedYear == nil)
        #expect(result.entries.isEmpty)
        #expect(marks.contains { $0.artist == "Daft Punk feat. Pharrell Williams" })
        #expect(marks.contains { $0.artist == "Daft Punk" })
        #expect(!marks.contains { $0.reason == "prerelease" })
        #expect(marks.allSatisfy { $0.reason == "no_year_found" })
        #expect(marks.allSatisfy { $0.metadata["lookup_artist"] == "Daft Punk" })
    }
}
