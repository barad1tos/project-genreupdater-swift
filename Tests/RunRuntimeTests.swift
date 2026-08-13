import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Run write runtime")
@MainActor
struct RunRuntimeTests {
    @Test("write runtime uses captured batch settings")
    func usesCapturedSettings() async throws {
        let track = Track(
            id: "AS-1",
            name: "Track 1",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 2000,
            trackStatus: TrackKind.subscription.rawValue,
            appleScriptID: "AS-1"
        )
        let script = RuntimeScriptSpy(track: track)
        let config = RuntimeConfigProbe()
        let services = RunServiceFactory(
            makeScripts: { configuration in
                await config.record(configuration)
                return script
            },
            makePendingVerification: { _ in
                // This runtime test does not exercise pending verification.
                nil
            }
        )
        let runtime = try await makeRuntime(services: services, script: script, track: track)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Artist"],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "write-runtime-test"
        )
        let planConfig = makePlanConfig()

        let writer = try await runtime.makeWrite(configuration: planConfig, scope: scope)
        let result = try await writer.coordinator.applyAcceptedChanges(
            makeChanges(track: track),
            progressHandler: { _ in }
        )

        #expect(result.appliedOperationCount == 2)
        #expect(await script.batchCalls.count == 1)
        #expect(await script.fetchCalls.map(\.batchSize) == [7])
        let captured = try #require(await config.last)
        #expect(captured.experimental.batchUpdatesEnabled)
        #expect(captured.experimental.maxBatchSize == 4)
        #expect(captured.applescript.batchProcessing.idsBatchSize == 7)
        #expect(captured.applescript.timeouts.idsBatchFetch == .seconds(45))
        #expect(captured.development.testArtists == ["Artist"])
    }

    private func makeRuntime(
        services: RunServiceFactory,
        script: RuntimeScriptSpy,
        track: Track
    ) async throws -> RunRuntimeFactory {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.saveTracks([track])
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let mapper = TrackIDMapper()
        await mapper.seedKnownMappings([(musicKitTrack: track, appleScriptTrack: track)])
        return RunRuntimeFactory(
            services: services,
            store: store,
            gate: FeatureGate(fixedTier: .pro),
            cache: cache,
            undo: UndoCoordinator(scriptBridge: script),
            mapper: mapper,
            reachability: nil,
            discogsAccessStore: DiscogsAccessStore()
        )
    }

    @Test("album preview narrows the sync read to the target artist")
    func albumTargetNarrowsSyncArtistScope() async throws {
        let track = Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")
        let script = RuntimeScriptSpy(track: track)
        let services = RunServiceFactory(
            makeScripts: { _ in script },
            makePendingVerification: { _ in
                // Scope derivation needs no pending verification.
                nil
            }
        )
        let factory = try await makeRuntime(services: services, script: script, track: track)
        let fullLibrary = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "sync-scope-pin"
        )
        let scoped = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Clutch", "Mastodon"],
            knownTrackCount: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "sync-scope-pin"
        )
        let target = FixPlanAlbumTarget(artist: "Clutch", album: "Blast Tyrant")
        let foreignTarget = FixPlanAlbumTarget(artist: "Anthrax", album: "Among the Living")

        // No target: the scope passes through untouched.
        #expect(factory.syncArtistScope(scope: fullLibrary, albumTarget: nil).isEmpty)
        // Full library + target does NOT narrow: the empty allow-list
        // passes every artist spelling; narrowing to the grouping
        // artist would drop feat-suffixed tracks at the coordinator
        // gate (identity-aware narrowing is ledgered).
        #expect(factory.syncArtistScope(scope: fullLibrary, albumTarget: target).isEmpty)
        // In-scope target narrows to that artist — a strict subset of
        // the scope's own gate semantics.
        #expect(factory.syncArtistScope(scope: scoped, albumTarget: target) == ["Clutch"])
        // Case-divergent spelling still narrows (normalized compare).
        let casedTarget = FixPlanAlbumTarget(artist: "CLUTCH", album: "Blast Tyrant")
        #expect(factory.syncArtistScope(scope: scoped, albumTarget: casedTarget) == ["CLUTCH"])
        // Out-of-scope target fails OPEN to the scope — never widen.
        #expect(factory.syncArtistScope(scope: scoped, albumTarget: foreignTarget)
            == scoped.normalizedTestArtists)
        // An unknown/blank target artist can never widen the read.
        let blankTarget = FixPlanAlbumTarget(artist: "   ", album: "Untitled")
        #expect(factory.syncArtistScope(scope: scoped, albumTarget: blankTarget)
            == scoped.normalizedTestArtists)
    }

    private func makePlanConfig() -> FixPlanConfig {
        var configuration = AppConfiguration()
        configuration.development.testArtists = ["Live Artist"]
        configuration.experimental.batchUpdatesEnabled = true
        configuration.experimental.maxBatchSize = 4
        configuration.applescript.batchProcessing.idsBatchSize = 7
        configuration.applescript.timeouts.idsBatchFetch = .seconds(45)
        return FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func makeChanges(track: Track) -> [ProposedChange] {
        [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Metal",
                confidence: 90,
                source: "runtime-test"
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "2000",
                newValue: "2001",
                confidence: 90,
                source: "runtime-test"
            )
        ]
    }
}

private actor RuntimeConfigProbe {
    private(set) var last: AppConfiguration?

    func record(_ configuration: AppConfiguration) {
        last = configuration
    }
}

private actor RuntimeScriptSpy: AppleScriptClient {
    private var tracks: [String: Track]
    private(set) var fetchCalls: [ScriptFetchCall] = []
    private(set) var batchCalls: [[TrackPropertyUpdate]] = []

    init(track: Track) {
        tracks = [track.id: track]
    }

    func initialize() async throws {
        // The in-memory script test double has no external setup.
    }

    func runScript(name _: String, arguments _: [String], timeout _: Duration?) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout: Duration?
    ) async throws -> [Track] {
        fetchCalls.append(ScriptFetchCall(trackIDs: trackIDs, batchSize: batchSize, timeout: timeout))
        return trackIDs.compactMap { tracks[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        Array(tracks.keys)
    }

    func updateTrackProperty(
        trackID: String,
        property: String,
        value: String
    ) async throws -> AppleScriptWriteResult {
        apply(property: property, value: value, trackID: trackID)
        return .changed
    }

    func batchUpdateTracks(_ updates: [TrackPropertyUpdate]) async throws {
        batchCalls.append(updates)
        for update in updates {
            apply(property: update.property, value: update.value, trackID: update.trackID)
        }
    }

    private func apply(property: String, value: String, trackID: String) {
        guard var track = tracks[trackID] else { return }
        switch property {
        case "genre":
            track.genre = value
        case "year":
            track.year = Int(value)
        default:
            break
        }
        tracks[trackID] = track
    }
}
