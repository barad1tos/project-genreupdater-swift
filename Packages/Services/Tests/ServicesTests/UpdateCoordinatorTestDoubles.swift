import Core
import Foundation

actor APIRequestProbe {
    private(set) var requestCount = 0

    func recordRequest() {
        requestCount += 1
    }
}

struct UpdateCoordinatorRecordingAPIService: ExternalAPIService {
    let probe: APIRequestProbe
    let yearResult: YearResult
    let releaseCandidates: [ReleaseCandidate]

    init(
        probe: APIRequestProbe,
        yearResult: YearResult = YearResult(),
        releaseCandidates: [ReleaseCandidate] = []
    ) {
        self.probe = probe
        self.yearResult = yearResult
        self.releaseCandidates = releaseCandidates
    }

    func getAlbumYear(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await probe.recordRequest()
        return yearResult
    }

    func getReleaseCandidates(
        artist _: String,
        album _: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await probe.recordRequest()
        return releaseCandidates
    }

    func getArtistActivityPeriod(normalizedArtist _: String) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(normalizedArtist _: String) async throws -> Int? {
        nil
    }

    func initialize(force _: Bool) async throws {}
    func close() async {}
}

actor PendingVerificationProbe: PendingVerificationService {
    let entry: PendingAlbumEntry?
    let isVerificationNeededResult: Bool
    private(set) var markedAlbums: [PendingVerificationMark] = []

    init(entry: PendingAlbumEntry?, isVerificationNeeded: Bool) {
        self.entry = entry
        isVerificationNeededResult = isVerificationNeeded
    }

    func initialize() async throws {}

    func markForVerification(
        artist: String,
        album: String,
        reason: String,
        metadata: [String: String]?,
        recheckDays: Int?
    ) async {
        markedAlbums.append(PendingVerificationMark(
            artist: artist,
            album: album,
            reason: reason,
            metadata: metadata ?? [:],
            recheckDays: recheckDays
        ))
    }

    func removeFromPending(artist _: String, album _: String) async {}

    func getEntry(artist _: String, album _: String) async -> PendingAlbumEntry? {
        entry
    }

    func getAttemptCount(artist _: String, album _: String) async -> Int {
        entry?.attemptCount ?? 0
    }

    func isVerificationNeeded(artist _: String, album _: String) async -> Bool {
        isVerificationNeededResult
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        entry.map { [$0] } ?? []
    }

    func generateProblematicAlbumsReport(minAttempts _: Int, reportURL _: URL?) async throws -> Int {
        0
    }

    func shouldAutoVerify() async -> Bool {
        false
    }

    func updateVerificationTimestamp() async throws {}
}

struct PendingVerificationMark {
    let artist: String
    let album: String
    let reason: String
    let metadata: [String: String]
    let recheckDays: Int?
}
