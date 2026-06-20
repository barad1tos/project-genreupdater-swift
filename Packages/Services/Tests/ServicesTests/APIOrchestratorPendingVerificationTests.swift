import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator - pending verification sync")
struct APIOrchestratorPendingVerificationTests {
    @Test("Marks album pending when APIs return no usable year")
    func noUsableYearMarksPendingVerification() async {
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult()),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        ) {
            $0.pendingVerificationService = pendingVerification
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Nobody",
            album: "Nothing",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let mark = await pendingVerification.firstMark()
        #expect(result.year == nil)
        #expect(mark?.artist == "Nobody")
        #expect(mark?.album == "Nothing")
        #expect(mark?.reason == "no_year_found")
        #expect(mark?.metadata["source"] == "api_orchestrator")
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Falls back to valid library year when APIs return no usable year")
    func noUsableYearFallsBackToValidLibraryYearAndKeepsPendingVerification() async {
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult()),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        ) {
            $0.pendingVerificationService = pendingVerification
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Clutch",
            album: "Pure Rock Fury",
            currentLibraryYear: 2001,
            earliestTrackAddedYear: 1999
        )

        let mark = await pendingVerification.firstMark()
        #expect(result.year == 2001)
        #expect(result.isDefinitive == false)
        #expect(result.confidence == 0)
        #expect(result.yearScores.isEmpty)
        #expect(mark?.artist == "Clutch")
        #expect(mark?.album == "Pure Rock Fury")
        #expect(mark?.reason == "no_year_found")
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Rejects current-year library fallback without a current add date")
    func noUsableYearRejectsSuspiciousCurrentYearFallback() async {
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(yearResult: YearResult()),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        ) {
            $0.pendingVerificationService = pendingVerification
        }
        let currentYear = Calendar.current.component(.year, from: Date())

        let result = await orchestrator.getAlbumYear(
            artist: "Future Noise",
            album: "Auto Tagged",
            currentLibraryYear: currentYear,
            earliestTrackAddedYear: nil
        )

        let mark = await pendingVerification.firstMark()
        #expect(result.year == nil)
        #expect(mark?.artist == "Future Noise")
        #expect(mark?.album == "Auto Tagged")
        #expect(mark?.reason == "no_year_found")
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Marks album pending when API year is not definitive")
    func nonDefinitiveYearMarksPendingVerification() async {
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(
                    year: 1994,
                    isDefinitive: false,
                    confidence: 72,
                    yearScores: [1994: 72]
                )
            ),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        ) {
            $0.pendingVerificationService = pendingVerification
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Portishead",
            album: "Dummy",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let mark = await pendingVerification.firstMark()
        #expect(result.year == 1994)
        #expect(result.isDefinitive == false)
        #expect(mark?.artist == "Portishead")
        #expect(mark?.album == "Dummy")
        #expect(mark?.metadata["candidate_year"] == "1994")
        #expect(mark?.metadata["confidence"] == "72")
        #expect(await pendingVerification.removalCount() == 0)
    }

    @Test("Removes album from pending when API result is definitive")
    func definitiveYearRemovesPendingVerification() async {
        let pendingVerification = RecordingPendingVerificationService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(
                    year: 1984,
                    confidence: 80,
                    yearScores: [1984: 80]
                )
            ),
            discogs: MockAPIService(
                yearResult: YearResult(
                    year: 1984,
                    confidence: 75,
                    yearScores: [1984: 75]
                )
            ),
            appleMusic: MockAPIService(shouldThrow: true)
        ) {
            $0.pendingVerificationService = pendingVerification
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let removal = await pendingVerification.firstRemoval()
        #expect(result.year == 1984)
        #expect(result.isDefinitive)
        #expect(await pendingVerification.markCount() == 0)
        #expect(removal?.artist == "Iron Maiden")
        #expect(removal?.album == "Powerslave")
    }

    @Test("Removes album from pending when verification attempts are exhausted")
    func exhaustedVerificationAttemptsRemovePendingVerification() async {
        let pendingVerification = RecordingPendingVerificationService(attemptCount: 3)
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(
                    year: 1997,
                    isDefinitive: false,
                    confidence: 55,
                    yearScores: [1997: 55]
                )
            ),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        ) {
            $0.pendingVerificationService = pendingVerification
            $0.maxVerificationAttempts = 3
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Deftones",
            album: "Around the Fur",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        let removal = await pendingVerification.firstRemoval()
        #expect(result.year == 1997)
        #expect(result.isDefinitive == false)
        #expect(await pendingVerification.markCount() == 0)
        #expect(removal?.artist == "Deftones")
        #expect(removal?.album == "Around the Fur")
    }
}

actor RecordingPendingVerificationService: PendingVerificationService {
    struct PendingMark: Equatable {
        let artist: String
        let album: String
        let reason: String
        let metadata: [String: String]
    }

    struct PendingRemoval: Equatable {
        let artist: String
        let album: String
    }

    private var marks: [PendingMark] = []
    private var removals: [PendingRemoval] = []
    private let attemptCount: Int

    init(attemptCount: Int = 0) {
        self.attemptCount = attemptCount
    }

    func initialize() async throws {}

    func markForVerification(
        artist: String,
        album: String,
        reason: String,
        metadata: [String: String]?,
        recheckDays _: Int?
    ) async {
        marks.append(PendingMark(
            artist: artist,
            album: album,
            reason: reason,
            metadata: metadata ?? [:]
        ))
    }

    func removeFromPending(artist: String, album: String) async {
        removals.append(PendingRemoval(artist: artist, album: album))
    }

    func getEntry(artist _: String, album _: String) async -> PendingAlbumEntry? {
        nil
    }

    func getAttemptCount(artist _: String, album _: String) async -> Int {
        attemptCount
    }

    func isVerificationNeeded(artist _: String, album _: String) async -> Bool {
        false
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        []
    }

    func generateProblematicAlbumsReport(minAttempts _: Int, reportURL _: URL?) async throws -> Int {
        0
    }

    func shouldAutoVerify() async -> Bool {
        false
    }

    func updateVerificationTimestamp() async throws {}

    func markCount() -> Int {
        marks.count
    }

    func firstMark() -> PendingMark? {
        marks.first
    }

    func removalCount() -> Int {
        removals.count
    }

    func firstRemoval() -> PendingRemoval? {
        removals.first
    }
}
