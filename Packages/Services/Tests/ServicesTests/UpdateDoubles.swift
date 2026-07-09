import Core
import Foundation

actor APIRequestProbe {
    private(set) var requestCount = 0
    private(set) var albumRequests: [(artist: String, album: String)] = []
    private(set) var activityPeriodRequests: [String] = []

    func recordRequest(artist: String, album: String) {
        requestCount += 1
        albumRequests.append((artist: artist, album: album))
    }

    func recordActivityPeriodRequest(normalizedArtist: String) {
        activityPeriodRequests.append(normalizedArtist)
    }
}

struct UpdateAPIDouble: ExternalAPIService {
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
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> YearResult {
        await probe.recordRequest(artist: artist, album: album)
        return yearResult
    }

    func getReleaseCandidates(
        artist: String,
        album: String,
        currentLibraryYear _: Int?,
        earliestTrackAddedYear _: Int?
    ) async throws -> [ReleaseCandidate] {
        await probe.recordRequest(artist: artist, album: album)
        return releaseCandidates
    }

    func getArtistActivityPeriod(normalizedArtist: String) async throws -> (start: Int?, end: Int?) {
        await probe.recordActivityPeriodRequest(normalizedArtist: normalizedArtist)
        return (nil, nil)
    }

    func initialize(force _: Bool) async throws {
        try Task.checkCancellation()
    }
}

actor PendingVerificationProbe: PendingVerificationService {
    let entries: [String: PendingAlbumEntry]
    let isVerificationNeededResult: Bool
    private(set) var markedAlbums: [PendingVerificationMark] = []
    private(set) var removedAlbums: [PendingVerificationRemoval] = []

    init(entry: PendingAlbumEntry?, isVerificationNeeded: Bool) {
        if let entry {
            entries = [Self.key(artist: entry.artist, album: entry.album): entry]
        } else {
            entries = [:]
        }
        isVerificationNeededResult = isVerificationNeeded
    }

    init(entries: [PendingAlbumEntry], isVerificationNeeded: Bool) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { entry in
            (Self.key(artist: entry.artist, album: entry.album), entry)
        })
        isVerificationNeededResult = isVerificationNeeded
    }

    func initialize() async throws {
        try Task.checkCancellation()
    }

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

    func removeFromPending(artist: String, album: String) async {
        removedAlbums.append(PendingVerificationRemoval(artist: artist, album: album))
    }

    func getEntry(artist: String, album: String) async -> PendingAlbumEntry? {
        entries[Self.key(artist: artist, album: album)]
    }

    func getAttemptCount(artist: String, album: String) async -> Int {
        entries[Self.key(artist: artist, album: album)]?.attemptCount ?? 0
    }

    func isVerificationNeeded(artist: String, album: String) async -> Bool {
        guard entries[Self.key(artist: artist, album: album)] != nil else { return true }
        return isVerificationNeededResult
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        Array(entries.values)
    }

    func shouldAutoVerify() async -> Bool {
        false
    }

    func updateVerificationTimestamp() async throws {
        try Task.checkCancellation()
    }

    private static func key(artist: String, album: String) -> String {
        AlbumIdentity.key(artist: artist, album: album)
    }
}

struct PendingVerificationMark {
    let artist: String
    let album: String
    let reason: String
    let metadata: [String: String]
    let recheckDays: Int?
}

struct PendingVerificationRemoval {
    let artist: String
    let album: String
}
