import Core
import Foundation
import Services

struct RunConfigSnapshot: Sendable {
    let libraryPaths: [String]
    let testArtists: [[String]]
    let verificationDays: [Int]
}

actor RunConfigProbe {
    private var libraryPaths: [String] = []
    private var testArtists: [[String]] = []
    private var verificationDays: [Int] = []

    func recordScriptConfig(_ configuration: AppConfiguration) {
        libraryPaths.append(configuration.paths.musicLibraryPath)
        testArtists.append(configuration.development.testArtists)
    }

    func recordPendingConfig(_ configuration: AppConfiguration) {
        verificationDays.append(configuration.processing.pendingVerificationIntervalDays)
    }

    func snapshot() -> RunConfigSnapshot {
        RunConfigSnapshot(
            libraryPaths: libraryPaths,
            testArtists: testArtists,
            verificationDays: verificationDays
        )
    }
}

actor ScopedReadProvider: LibraryReadProvider {
    let artists: [String]

    init(artists: [String]) {
        self.artists = artists
    }

    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        LibraryReadSnapshot(tracks: [], scannedAt: Date(timeIntervalSince1970: 100))
    }
}

actor PreviewScriptClient: AppleScriptClient {
    private let tracks: [Track]
    private var fetchedArtistScopes: [String?] = []
    private var fetchedArtistTimeouts: [Duration?] = []
    private var fetchedTrackTimeouts: [Duration?] = []
    private var allTrackIDFetches = 0

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func initialize() async throws {
        // This in-memory test client has no external resources to initialize.
    }

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(_ trackIDs: [String], batchSize _: Int, timeout: Duration?) async throws -> [Track] {
        fetchedTrackTimeouts.append(timeout)
        return tracks.filter { trackIDs.contains($0.id) }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        allTrackIDFetches += 1
        return tracks.map(\.id)
    }

    func fetchTracks(artist: String?, timeout: Duration?) async throws -> [Track] {
        fetchedArtistScopes.append(artist)
        fetchedArtistTimeouts.append(timeout)
        return tracks
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws
        -> AppleScriptWriteResult {
        throw PreviewScriptError.unexpectedWrite
    }

    func batchUpdateTracks(_: [TrackPropertyUpdate]) async throws {
        throw PreviewScriptError.unexpectedWrite
    }

    func artistScopes() -> [String?] {
        fetchedArtistScopes
    }

    func artistTimeouts() -> [Duration?] {
        fetchedArtistTimeouts
    }

    func trackTimeouts() -> [Duration?] {
        fetchedTrackTimeouts
    }

    func allTrackIDFetchCount() -> Int {
        allTrackIDFetches
    }
}

enum PreviewScriptError: Error {
    case unexpectedWrite
}

func musicKitTrack(id: String, name: String = "Track") -> Track {
    Track(id: id, name: name, artist: "probe artist", album: "Album")
}

func appleScriptTrack(id: String, name: String = "Track") -> Track {
    Track(id: id, name: name, artist: "probe artist", album: "Album", appleScriptID: id)
}

actor PreviewProducerProbe {
    nonisolated let producedAt = Date(timeIntervalSince1970: 1_800_000_100)
    private let track = Track(
        id: "track-1",
        name: "Preview Track",
        artist: "Probe Artist",
        album: "Probe Album",
        genre: "Rock",
        year: 2000,
        trackStatus: "purchased"
    )
    private let albumPeer = Track(
        id: "album-peer",
        name: "Album Peer",
        artist: "Probe Artist",
        album: "Probe Album",
        genre: "Rock",
        year: 2001,
        trackStatus: "purchased"
    )
    private var loadCallCount = 0
    private var refreshInputIDs: [String] = []
    private var refreshScope: ProcessingScopeSnapshot?
    private var albumContextInputIDs: [String] = []
    private var determinedTrackID: String?
    private var determinedAlbumIDs: [String] = []
    private var determinedArtistIDs: [String] = []
    private var options: UpdateOptions?
    private var savedPlan: FixPlan?
    private var savedDecision: FixPlanReviewDecision?

    func loadTracks() -> [Track] {
        loadCallCount += 1
        return [track]
    }

    func refreshWriteIdentity(for tracks: [Track], scope: ProcessingScopeSnapshot) {
        refreshInputIDs = tracks.map(\.id)
        refreshScope = scope
    }

    func albumContextTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        albumContextInputIDs = tracks.map(\.id)
        return [track.id: [albumPeer]]
    }

    func determineTrackChanges(
        track: Track,
        albumTracks: [Track],
        artistTracks: [Track],
        options: UpdateOptions
    ) throws -> [ProposedChange] {
        determinedTrackID = track.id
        determinedAlbumIDs = albumTracks.map(\.id)
        determinedArtistIDs = artistTracks.map(\.id)
        self.options = options
        return [
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "2000",
                newValue: "2001",
                confidence: options.minConfidence,
                source: "test"
            )
        ]
    }

    func savePlan(_ plan: FixPlan, initialDecision: FixPlanReviewDecision) {
        savedPlan = plan
        savedDecision = initialDecision
    }

    func snapshot() -> PreviewProducerProbeSnapshot {
        PreviewProducerProbeSnapshot(
            loadedCount: loadCallCount,
            refreshInputIDs: refreshInputIDs,
            refreshScope: refreshScope,
            albumContextInputIDs: albumContextInputIDs,
            determinedTrackID: determinedTrackID,
            determinedAlbumIDs: determinedAlbumIDs,
            determinedArtistIDs: determinedArtistIDs,
            options: options,
            savedPlan: savedPlan,
            savedDecision: savedDecision
        )
    }
}

struct PreviewProducerProbeSnapshot {
    let loadedCount: Int
    let refreshInputIDs: [String]
    let refreshScope: ProcessingScopeSnapshot?
    let albumContextInputIDs: [String]
    let determinedTrackID: String?
    let determinedAlbumIDs: [String]
    let determinedArtistIDs: [String]
    let options: UpdateOptions?
    let savedPlan: FixPlan?
    let savedDecision: FixPlanReviewDecision?
}
