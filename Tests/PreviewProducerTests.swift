import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview producer")
@MainActor
struct PreviewProducerTests {
    @Test("uses supplied options and saves a plan")
    func savesPlan() async throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 73
        let dependencies = AppDependencies(
            configurationLoader: { configuration },
            configurationSaver: { _ in
                // This test only verifies preview option resolution, not config persistence.
            }
        )
        let probe = PreviewProducerProbe()
        let producer = dependencies.makePreviewProducer(
            dependencies: FixPlanProducer.Dependencies(
                loadTracks: { await probe.loadTracks() },
                refreshWriteIdentity: { await probe.refreshWriteIdentity(for: $0, scope: $1) },
                albumContextTracksByTrackID: { await probe.albumContextTracksByTrackID(for: $0) },
                determineTrackChanges: {
                    try await probe.determineTrackChanges(
                        track: $0,
                        albumTracks: $1,
                        artistTracks: $2,
                        options: $3
                    )
                },
                savePlan: { await probe.savePlan($0, initialDecision: $1) },
                now: { probe.producedAt }
            ),
            options: PreviewRunOptions.make(
                configuration: configuration,
                updateGenre: false,
                updateYear: true
            )
        )
        let runID = RunID()
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Probe Artist"],
            knownTrackCount: 1,
            createdAt: probe.producedAt,
            reason: "previewProducerTest"
        )

        let production = try await producer(runID, scope)
        let snapshot = await probe.snapshot()

        #expect(production.proposalCount == 1)
        #expect(production.planID == snapshot.savedPlan?.id)
        #expect(snapshot.loadedCount == 1)
        #expect(snapshot.refreshInputIDs == ["track-1"])
        #expect(snapshot.refreshScope == scope)
        #expect(snapshot.albumContextInputIDs == ["track-1"])
        #expect(snapshot.determinedTrackID == "track-1")
        #expect(snapshot.determinedAlbumIDs == ["album-peer"])
        #expect(snapshot.determinedArtistIDs == ["track-1"])
        #expect(snapshot.options?.updateGenre == false)
        #expect(snapshot.options?.updateYear == true)
        #expect(snapshot.options?.minConfidence == 73)
        #expect(snapshot.savedPlan?.sourceRunID == runID)
        #expect(snapshot.savedPlan?.configuration.updateGenre == false)
        #expect(snapshot.savedPlan?.configuration.updateYear == true)
        #expect(snapshot.savedPlan?.configuration.minConfidence == 73)
        #expect(snapshot.savedDecision?.planID == snapshot.savedPlan?.id)
        #expect(snapshot.savedDecision?.planRevision == snapshot.savedPlan?.revision)
    }

    @Test("write identity refresh forwards test artist scope")
    func refreshesTestArtistScope() async throws {
        let mapper = TrackIDMapper()
        let script = PreviewScriptClient(tracks: [appleScriptTrack(id: "AS-TRACK")])
        let refresh = PlanIdentityRefresh(mapper: mapper, client: script)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["probe artist"],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )

        try await refresh.run(tracks: [musicKitTrack(id: "MK-TRACK")], scope: scope, config: AppleScriptConfig())

        #expect(await script.artistScopes() == ["probe artist"])
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-TRACK") == "AS-TRACK")
    }

    @Test("full library refresh preserves existing mappings")
    func refreshesFullLibrary() async throws {
        let mapper = TrackIDMapper()
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack(id: "MK-OLD", name: "Old")],
            appleScriptTracks: [appleScriptTrack(id: "AS-OLD", name: "Old")]
        )
        let script = PreviewScriptClient(tracks: [appleScriptTrack(id: "AS-NEW", name: "New")])
        let refresh = PlanIdentityRefresh(mapper: mapper, client: script)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )

        try await refresh.run(
            tracks: [musicKitTrack(id: "MK-NEW", name: "New")],
            scope: scope,
            config: AppleScriptConfig()
        )

        #expect(await script.allTrackIDFetchCount() == 1)
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-OLD") == "AS-OLD")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-NEW") == "AS-NEW")
    }
}

private actor PreviewScriptClient: AppleScriptClient {
    private let tracks: [Track]
    private var fetchedArtistScopes: [String?] = []
    private var allTrackIDFetches = 0

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func initialize() async throws {}

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(_ trackIDs: [String], batchSize _: Int, timeout _: Duration?) async throws -> [Track] {
        tracks.filter { trackIDs.contains($0.id) }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        allTrackIDFetches += 1
        return tracks.map(\.id)
    }

    func fetchTracks(artist: String?, timeout _: Duration?) async throws -> [Track] {
        fetchedArtistScopes.append(artist)
        return tracks
    }

    func updateTrackProperty(trackID _: String, property _: String, value _: String) async throws
        -> AppleScriptWriteResult {
        throw PreviewScriptError.unexpectedWrite
    }

    func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
        throw PreviewScriptError.unexpectedWrite
    }

    func artistScopes() -> [String?] {
        fetchedArtistScopes
    }

    func allTrackIDFetchCount() -> Int {
        allTrackIDFetches
    }
}

private enum PreviewScriptError: Error {
    case unexpectedWrite
}

private func musicKitTrack(id: String, name: String = "Track") -> Track {
    Track(id: id, name: name, artist: "probe artist", album: "Album")
}

private func appleScriptTrack(id: String, name: String = "Track") -> Track {
    Track(id: id, name: name, artist: "probe artist", album: "Album", appleScriptID: id)
}

private actor PreviewProducerProbe {
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

private struct PreviewProducerProbeSnapshot {
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
