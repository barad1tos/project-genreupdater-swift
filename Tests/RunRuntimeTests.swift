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
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let mapper = TrackIDMapper()
        await mapper.seedKnownMappings([(musicKitTrack: track, appleScriptTrack: track)])
        return RunRuntimeFactory(
            services: services,
            store: TrackDataStore(modelContainer: container),
            gate: FeatureGate(fixedTier: .pro),
            cache: cache,
            undo: UndoCoordinator(scriptBridge: script),
            mapper: mapper,
            reachability: nil,
            discogsAccessStore: DiscogsAccessStore()
        )
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
            ),
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
    private(set) var fetchCalls: [(trackIDs: [String], batchSize: Int, timeout: Duration?)] = []
    private(set) var batchCalls: [[(trackID: String, property: String, value: String)]] = []

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
        fetchCalls.append((trackIDs, batchSize, timeout))
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

    func batchUpdateTracks(_ updates: [(trackID: String, property: String, value: String)]) async throws {
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
