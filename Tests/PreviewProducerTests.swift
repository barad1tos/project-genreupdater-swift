import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview producer")
@MainActor
struct PreviewProducerTests {
    private typealias Producer = @Sendable (
        RunID,
        ProcessingScopeSnapshot,
        FixPlanConfig
    ) async throws -> FixPlanProduction

    @Test("run services use each submitted configuration")
    func usesSubmittedConfiguration() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeScripts: { configuration in
                await probe.recordScriptConfig(configuration)
                return PreviewScriptClient(tracks: [])
            },
            makePendingVerification: { configuration in
                await probe.recordPendingConfig(configuration)
                return WorkflowPendingVerificationService(entries: [])
            }
        )
        let runtime = try await makeRuntime(services: services)
        let firstPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-config-first")
            .path
        let secondPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-config-second")
            .path
        let firstConfiguration = planConfiguration(path: firstPath, verificationDays: 7)
        let secondConfiguration = planConfiguration(path: secondPath, verificationDays: 21)

        _ = try await runtime.makeSync(
            configuration: firstConfiguration,
            scope: scope(artist: "First Artist")
        )
        _ = try await runtime.makePreview(
            configuration: firstConfiguration,
            scope: scope(artist: "First Artist")
        )
        _ = try await runtime.makeSync(
            configuration: secondConfiguration,
            scope: scope(artist: "Second Artist")
        )
        _ = try await runtime.makePreview(
            configuration: secondConfiguration,
            scope: scope(artist: "Second Artist")
        )

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [firstPath, secondPath])
        #expect(snapshot.verificationDays == [7, 21])
        #expect(snapshot.testArtists == [["First Artist"], ["Second Artist"]])
    }

    @Test("run services rebuild when a configuration changes under the same ID")
    func rebuildsChangedConfig() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeScripts: { configuration in
                await probe.recordScriptConfig(configuration)
                return PreviewScriptClient(tracks: [])
            },
            makePendingVerification: { _ in nil },
            makeReadProvider: { configuration in
                ScopedReadProvider(artists: configuration.development.testArtists)
            }
        )
        var first = AppConfiguration()
        let firstPath = FileManager.default.temporaryDirectory.appendingPathComponent("first").path
        let secondPath = FileManager.default.temporaryDirectory.appendingPathComponent("second").path
        first.paths.musicLibraryPath = firstPath
        first.development.testArtists = ["First Artist"]
        var second = first
        second.paths.musicLibraryPath = secondPath
        second.development.testArtists = ["Second Artist"]
        let id = UUID()

        let firstServices = try await services.prepare(id: id, configuration: first)
        let secondServices = try await services.consume(id: id, configuration: second)

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [firstPath, secondPath])
        #expect(try await readArtists(firstServices) == ["First Artist"])
        #expect(try await readArtists(secondServices) == ["Second Artist"])
    }

    @Test("discarded run services are rebuilt")
    func rebuildsDiscardedRun() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeScripts: { configuration in
                await probe.recordScriptConfig(configuration)
                return PreviewScriptClient(tracks: [])
            },
            makePendingVerification: { _ in nil }
        )
        var configuration = AppConfiguration()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("discarded-run").path
        configuration.paths.musicLibraryPath = path
        let id = UUID()

        _ = try await services.prepare(id: id, configuration: configuration)
        await services.discard(id: id)
        _ = try await services.consume(id: id, configuration: configuration)

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [path, path])
    }

    @Test("preview consumes submitted Discogs access")
    func consumesDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeScripts: { _ in PreviewScriptClient(tracks: []) },
            makePendingVerification: { _ in nil }
        )
        let accessStore = DiscogsAccessStore()
        let runtime = try await makeRuntime(services: services, accessStore: accessStore)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )
        await accessStore.save(
            .enabled(DiscogsClient(token: "submitted-token")),
            configurationID: configuration.id
        )

        _ = try await runtime.makePreview(configuration: configuration, scope: scope(artist: "Probe Artist"))

        #expect(await accessStore.consume(configurationID: configuration.id) == nil)
    }

    @Test("preview fails when submitted Discogs access is missing")
    func rejectsMissingDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeScripts: { _ in PreviewScriptClient(tracks: []) },
            makePendingVerification: { _ in nil }
        )
        let runtime = try await makeRuntime(services: services)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )

        do {
            _ = try await runtime.makePreview(configuration: configuration, scope: scope(artist: "Probe Artist"))
            Issue.record("Expected missing captured Discogs access to fail")
        } catch {
            #expect(error.localizedDescription == "Captured Discogs access is unavailable for this preview run")
        }
    }

    @Test("discard removes submitted Discogs access")
    func discardsDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeScripts: { _ in PreviewScriptClient(tracks: []) },
            makePendingVerification: { _ in nil }
        )
        let accessStore = DiscogsAccessStore()
        let runtime = try await makeRuntime(services: services, accessStore: accessStore)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )
        await accessStore.save(
            .enabled(DiscogsClient(token: "submitted-token")),
            configurationID: configuration.id
        )

        await runtime.discard(configuration)

        #expect(await accessStore.consume(configurationID: configuration.id) == nil)
    }

    private func readArtists(_ services: RunServices) async throws -> [String] {
        let provider = try #require(services.readProvider as? ScopedReadProvider)
        return provider.artists
    }

    private func makeRuntime(
        services: RunServiceFactory,
        accessStore: DiscogsAccessStore = DiscogsAccessStore()
    ) async throws -> RunRuntimeFactory {
        let container = try ModelContainerFactory.createInMemory()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let script = PreviewScriptClient(tracks: [])
        return RunRuntimeFactory(
            services: services,
            store: TrackDataStore(modelContainer: container),
            gate: FeatureGate(fixedTier: .pro),
            cache: cache,
            undo: UndoCoordinator(scriptBridge: script),
            mapper: TrackIDMapper(),
            reachability: nil,
            discogsAccessStore: accessStore
        )
    }

    private func planConfiguration(path: String, verificationDays: Int) -> FixPlanConfig {
        var configuration = AppConfiguration()
        configuration.paths.musicLibraryPath = path
        configuration.processing.pendingVerificationIntervalDays = verificationDays
        return FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: TimeInterval(verificationDays))
        )
    }

    private func scope(artist: String) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot.capture(
            requestedTestArtists: [artist],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )
    }

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
        let producer = makeProducer(dependencies: dependencies, probe: probe)
        let planConfiguration = FixPlanConfig.capture(
            configuration: configuration,
            options: PreviewRunOptions.make(
                configuration: configuration,
                updateGenre: false,
                updateYear: true
            ),
            capturedAt: Date(timeIntervalSince1970: 50)
        )
        let runID = RunID()
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Probe Artist"],
            knownTrackCount: 1,
            createdAt: probe.producedAt,
            reason: "previewProducerTest"
        )

        let production = try await producer(runID, scope, planConfiguration)
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
        #expect(snapshot.savedPlan?.configuration.id == planConfiguration.id)
        #expect(snapshot.savedPlan?.configuration.updateGenre == false)
        #expect(snapshot.savedPlan?.configuration.updateYear == true)
        #expect(snapshot.savedPlan?.configuration.minConfidence == 73)
        #expect(snapshot.savedDecision?.planID == snapshot.savedPlan?.id)
        #expect(snapshot.savedDecision?.planRevision == snapshot.savedPlan?.revision)
    }

    private func makeProducer(
        dependencies: AppDependencies,
        probe: PreviewProducerProbe
    ) -> Producer {
        dependencies.makePreviewProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { await probe.loadTracks() },
            makeRuntime: { _, _ in
                FixPlanProducer.Runtime(
                    refreshIdentity: { await probe.refreshWriteIdentity(for: $0, scope: $1) },
                    albumContext: { await probe.albumContextTracksByTrackID(for: $0) },
                    determineChanges: {
                        try await probe.determineTrackChanges(
                            track: $0,
                            albumTracks: $1,
                            artistTracks: $2,
                            options: $3
                        )
                    }
                )
            },
            savePlan: { await probe.savePlan($0, initialDecision: $1) },
            now: { probe.producedAt }
        ))
    }

    @Test("write identity refresh forwards test artist scope")
    func refreshesTestArtistScope() async throws {
        let mapper = TrackIDMapper()
        let script = PreviewScriptClient(tracks: [appleScriptTrack(id: "AS-TRACK")])
        let refresher = WriteIdentityRefresher(mapper: mapper, client: script)
        var config = AppleScriptConfig()
        config.timeouts.fullLibraryFetch = .seconds(91)
        config.timeouts.singleArtistFetch = .seconds(37)
        config.timeouts.idsBatchFetch = .seconds(7)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["probe artist"],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )

        try await refresher.refresh(
            tracks: [musicKitTrack(id: "MK-TRACK")],
            scope: scope,
            config: config
        )

        #expect(await script.artistScopes() == ["probe artist"])
        #expect(await script.artistTimeouts() == [.seconds(37)])
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
        let refresher = WriteIdentityRefresher(mapper: mapper, client: script)
        var config = AppleScriptConfig()
        config.timeouts.fullLibraryFetch = .seconds(91)
        config.timeouts.idsBatchFetch = .seconds(7)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )

        try await refresher.refresh(
            tracks: [musicKitTrack(id: "MK-NEW", name: "New")],
            scope: scope,
            config: config
        )

        #expect(await script.allTrackIDFetchCount() == 1)
        #expect(await script.trackTimeouts() == [.seconds(7)])
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-OLD") == "AS-OLD")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-NEW") == "AS-NEW")
    }
}

private actor RunConfigProbe {
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

    func snapshot() -> (libraryPaths: [String], testArtists: [[String]], verificationDays: [Int]) {
        (libraryPaths, testArtists, verificationDays)
    }
}

private actor ScopedReadProvider: LibraryReadProvider {
    let artists: [String]

    init(artists: [String]) {
        self.artists = artists
    }

    func loadLibrarySnapshot(request _: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        LibraryReadSnapshot(tracks: [], scannedAt: Date(timeIntervalSince1970: 100))
    }
}

private actor PreviewScriptClient: AppleScriptClient {
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

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
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
