import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — artist start year parity")
struct ArtistStartTests {
    @Test("Artist start fallback preserves existing year when proposed API year predates artist")
    func artistStartFallbackPreservesExistingYearWhenProposedYearPredatesArtist() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 60,
            yearScores: [1990: 60, 2020: 10]
        )
        let musicBrainz = MockAPIService(yearResult: apiResult)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService(artistStartYear: 2000)
        )
        let coordinator = makeCoordinator(apiOrchestrator: orchestrator)
        let track = Track(
            id: "T1",
            name: "Modern Track",
            artist: "Test Artist",
            album: "Modern Album",
            year: 2020
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
    }

    @Test("Artist start fallback uses album identity artist for collaborations")
    func artistStartFallbackUsesAlbumIdentityArtistForCollaborations() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 60,
            yearScores: [1990: 60, 2020: 10]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: apiResult),
            discogs: MockAPIService(),
            appleMusic: ArtistStartLookupAPIService(startYearsByArtist: ["daft punk": 2000])
        )
        let coordinator = makeCoordinator(apiOrchestrator: orchestrator)
        let track = Track(
            id: "T1",
            name: "Modern Track",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Modern Album",
            year: 2020
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
    }

    @Test("Artist start fallback uses track artist instead of album artist")
    func artistStartFallbackUsesTrackArtistInsteadOfAlbumArtist() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 60,
            yearScores: [1990: 60, 2020: 10]
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: apiResult),
            discogs: MockAPIService(),
            appleMusic: ArtistStartLookupAPIService(startYearsByArtist: ["modern artist": 2000])
        )
        let coordinator = makeCoordinator(apiOrchestrator: orchestrator)
        let track = Track(
            id: "T1",
            name: "Modern Track",
            artist: "Modern Artist",
            album: "Compilation",
            year: 2020,
            albumArtist: "Various Artists"
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
    }

    @Test("Matching implausible year is marked for verification")
    func marksImplausibleMatchingYear() async throws {
        let apiResult = YearResult(
            year: 1990,
            confidence: 100,
            yearScores: [1990: 100]
        )
        let musicBrainz = MockAPIService(
            yearResult: apiResult,
            artistActivityPeriod: (start: 2000, end: nil)
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let pendingStore = try PendingVerificationStore(
            modelContainer: ModelContainerFactory.createInMemory(),
            legacyStorageURL: nil
        )
        try await pendingStore.initialize()
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingStore
        )
        let track = Track(
            id: "T1",
            name: "Early Track",
            artist: "Test Artist",
            album: "Early Album",
            year: 1990
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        let pendingEntry = await pendingStore.getEntry(
            artist: "Test Artist",
            album: "Early Album"
        )
        let firstAttemptCount = await pendingStore.getAttemptCount(
            artist: "Test Artist",
            album: "Early Album"
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
        #expect(pendingEntry?.reason == "implausible_matching_year")
        #expect(pendingEntry?.metadata["year"] == "1990")
        #expect(pendingEntry?.metadata["artist_start_year"] == "2000")
        #expect(pendingEntry?.metadata["note"] == "Both library and API returned same impossible year")
        #expect(pendingEntry?.metadata["plausibility"] == "year_before_artist_start")
        #expect(firstAttemptCount == 1)

        _ = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        let secondAttemptCount = await pendingStore.getAttemptCount(
            artist: "Test Artist",
            album: "Early Album"
        )

        #expect(secondAttemptCount == 1)
    }

    @Test("Confirmed miss marks the album without misclassifying the library fallback")
    func marksConfirmedMiss() async throws {
        let musicBrainz = MockAPIService(
            artistActivityPeriod: (start: 2000, end: nil)
        )
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: musicBrainz,
            discogs: MockAPIService(),
            appleMusic: MockAPIService()
        )
        let pendingStore = try PendingVerificationStore(
            modelContainer: ModelContainerFactory.createInMemory(),
            legacyStorageURL: nil
        )
        try await pendingStore.initialize()
        let coordinator = makeCoordinator(
            apiOrchestrator: orchestrator,
            pendingVerificationService: pendingStore
        )
        let track = Track(
            id: "T1",
            name: "Early Track",
            artist: "Test Artist",
            album: "Early Album",
            year: 1990
        )

        let changes = try await coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        let pendingEntry = await pendingStore.getEntry(
            artist: "Test Artist",
            album: "Early Album"
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
        #expect(pendingEntry?.reason == "no_year_found")
        #expect(pendingEntry?.metadata.isEmpty == true)
    }

    private func makeCoordinator(
        apiOrchestrator: APIOrchestrator,
        pendingVerificationService: (any PendingVerificationService)? = nil
    ) -> UpdateCoordinator {
        let bridge = MusicAppTestAccess()
        let store = MockTrackStore()
        let cache = MockCacheService()
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistStartTests-\(UUID().uuidString)")
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: apiOrchestrator,
                writer: bridge,
                stores: .init(
                    trackStore: store,
                    cache: cache
                ),
                undoCoordinator: UndoCoordinator(
                    musicApp: bridge,
                    directory: undoDirectory
                ),
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(
                policies: UpdateRuntimeConfiguration.Policies(missingYearThreshold: 30)
            )
        )
    }
}

private struct ArtistStartLookupAPIService: ExternalAPIService {
    let startYearsByArtist: [String: Int]

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        YearResult()
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        []
    }

    func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        startYearsByArtist[normalizedArtist]
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}
