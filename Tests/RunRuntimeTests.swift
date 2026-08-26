import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Run write runtime")
@MainActor
struct RunRuntimeTests {
    @Test("headless scheduled auto-fix uses the app composition end to end")
    func headlessAutoFixUsesAppComposition() async throws {
        var configuration = AppConfiguration()
        configuration.runtime.dryRun = false
        configuration.runtime.automationStrategy = .scheduled
        configuration.processing.defaultUpdateBehavior = .genreOnly
        configuration.genreUpdate.overrideExisting = true
        configuration.cleaning.genreMappings = ["Rock": "Metal"]
        configuration.yearRetrieval.enabled = false
        configuration.experimental.batchUpdatesEnabled = true

        let track = Track(
            id: "AS-1",
            name: "Track 1",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            dateAdded: Date(timeIntervalSince1970: 50),
            trackStatus: TrackKind.subscription.rawValue,
            appleScriptID: "AS-1"
        )
        let fixture = try await makeCompositionFixture(configuration: configuration, track: track)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let directChanges = try await fixture.proposedChanges(configuration: configuration)
        #expect(directChanges.map(\.changeType) == [.genreUpdate])

        await fixture.dependencies.submitScheduledProcessing()

        let records = try await fixture.runStore.loadAll().filter { $0.finishedAt != nil }
        #expect(records.map(\.intent) == [.writeFixes, .previewFixes])
        #expect(records.first?.configuration?.writeAuthority == .automaticPlan)
        #expect(records.first?.writeSummary?.applied == 1)
        #expect(await fixture.script.storedTrack(id: track.id)?.genre == "Metal")
        #expect(await fixture.tracker.getLastRunTimestamp() != nil)
        #expect(fixture.dependencies.lastIncrementalRunTimestamp != nil)
    }

    @Test("Live Free access overrides captured paid cache settings")
    func freeAccessOverridesCapturedCache() async throws {
        let track = Track(id: "cache-track", name: "Track", artist: "Artist", album: "Album")
        let script = RuntimeScriptSpy(track: track)
        let services = RunServiceFactory(
            makeMusicAccess: { _ in
                RunMusicAccess(identifier: script, writer: script, observer: MusicAppTestObserver(tracks: [track]))
            },
            makePendingVerification: { _ in nil }
        )

        let prepared = try await services.prepareObservation(id: UUID(), configuration: AppConfiguration())
        #expect(prepared.observer is MusicAppTestObserver)
        let runtime = try await makeRuntime(
            services: services,
            script: script,
            track: track,
            gate: FeatureGate(fixedTier: .free)
        )
        var captured = AppConfiguration()
        captured.runtime.cacheTTLSeconds = 7200
        captured.runtime.maxGenericEntries = 20000
        captured.caching.defaultTTLSeconds = 3600
        captured.caching.negativeResultTTL = 7200
        captured.caching.librarySnapshot.enabled = false
        captured.caching.librarySnapshot.maxAgeHours = 72
        captured.processing.cacheTTLDays = 30

        let effective = runtime.cacheConfiguration(for: captured)
        let defaults = AppConfiguration()

        #expect(effective.runtime.cacheTTLSeconds == defaults.runtime.cacheTTLSeconds)
        #expect(effective.runtime.maxGenericEntries == defaults.runtime.maxGenericEntries)
        #expect(effective.caching.defaultTTLSeconds == defaults.caching.defaultTTLSeconds)
        #expect(effective.caching.negativeResultTTL == defaults.caching.negativeResultTTL)
        #expect(effective.caching.librarySnapshot.enabled == defaults.caching.librarySnapshot.enabled)
        #expect(effective.caching.librarySnapshot.maxAgeHours == defaults.caching.librarySnapshot.maxAgeHours)
        #expect(effective.processing.cacheTTLDays == defaults.processing.cacheTTLDays)
    }

    @Test("write runtime preserves captured write settings")
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
            makeMusicAccess: { configuration in
                await config.record(configuration)
                return RunMusicAccess(
                    identifier: script,
                    writer: script,
                    observer: MusicAppTestObserver(tracks: [track])
                )
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
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "AS-1"))
        #expect(await script.metadataFetches == [[databaseID]])
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
        track: Track,
        gate: FeatureGate = FeatureGate(fixedTier: .pro)
    ) async throws -> RunRuntimeFactory {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([track])
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let mapper = TrackIDMapper()
        await mapper.seedKnownMappings([(musicKitTrack: track, appleScriptTrack: track)])
        return RunRuntimeFactory(
            services: services,
            store: store,
            gate: gate,
            cache: cache,
            undo: UndoCoordinator(musicApp: script),
            mapper: mapper,
            reachability: nil,
            discogsAccessStore: DiscogsAccessStore(),
            analytics: nil
        )
    }

    @Test("album preview narrows the sync read to the target artist")
    func albumTargetNarrowsSyncArtistScope() async throws {
        let track = Track(id: "t", name: "Song", artist: "Clutch", album: "Blast Tyrant")
        let script = RuntimeScriptSpy(track: track)
        let services = RunServiceFactory(
            makeMusicAccess: { _ in
                RunMusicAccess(identifier: script, writer: script, observer: MusicAppTestObserver(tracks: [track]))
            },
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

private struct CompositionFixture {
    let dependencies: AppDependencies
    let runStore: RunRecordDataStore
    let script: RuntimeScriptSpy
    let tracker: IncrementalRunTracker
    let directory: URL
    let runtime: RunRuntimeFactory
    let store: TrackDataStore

    @MainActor
    func proposedChanges(configuration: AppConfiguration) async throws -> [ProposedChange] {
        let capturedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: capturedAt,
            reason: "composition-positive-control"
        )
        let planConfiguration = FixPlanConfig.capture(
            configuration: configuration,
            options: PreviewRunOptions.make(configuration: configuration, updateGenre: true, updateYear: false),
            capturedAt: capturedAt
        )
        let tracks = try await store.loadAllTracks()
        let preview = try await runtime.makePreview(configuration: planConfiguration, scope: scope)
        try await preview.refreshIdentity(tracks, scope)
        let albums = await preview.albumContext(tracks)
        let artists = await preview.artistContext(tracks)
        guard let track = tracks.first else { return [] }
        return try await preview.determineChanges(
            track,
            albums[track.id] ?? [],
            artists[track.id] ?? [],
            planConfiguration.determinationOptions,
            YearRunScope()
        )
    }
}

private struct CompositionServices {
    let script: RuntimeScriptSpy
    let observer: MusicAppTestObserver
    let store: TrackDataStore
    let planStore: FixPlanDataStore
    let runStore: RunRecordDataStore
    let cache: GRDBCacheService
    let gate: FeatureGate
    let undo: UndoCoordinator
    let mapper: TrackIDMapper
    let discogsAccess: DiscogsAccessStore

    var runtime: RunRuntimeFactory {
        RunRuntimeFactory(
            services: RunServiceFactory(
                makeMusicAccess: { _ in
                    RunMusicAccess(identifier: script, writer: script, observer: observer)
                },
                makePendingVerification: { _ in nil }
            ),
            store: store,
            gate: gate,
            cache: cache,
            undo: undo,
            mapper: mapper,
            reachability: nil,
            discogsAccessStore: discogsAccess,
            analytics: nil
        )
    }
}

@MainActor
private func makeCompositionFixture(
    configuration: AppConfiguration,
    track: Track
) async throws -> CompositionFixture {
    let dependencies = AppDependencies(
        configurationLoader: { configuration },
        configurationSaver: { savedConfiguration in _ = savedConfiguration }
    )
    let services = try await makeCompositionServices(
        track: track,
        discogsAccess: dependencies.discogsAccessStore
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunComposition-\(UUID().uuidString)")
    let processor = BatchProcessor(
        checkpointManager: CheckpointManager(directory: directory),
        featureGate: services.gate
    )
    let tracker = IncrementalRunTracker(
        logsBaseDirectory: directory.path,
        lastIncrementalRunFile: "last-run.txt"
    )
    dependencies.installTestFeatureGate(services.gate)
    dependencies.installTestIncrementalRunTracker(tracker)
    dependencies.configureLibraryPersistenceForTesting(
        trackStore: services.store,
        runRecordStore: services.runStore,
        fixPlanStore: services.planStore,
        cache: services.cache
    )
    dependencies.installTestWrites(TestWriteServices(
        batchProcessor: processor,
        undoCoordinator: services.undo,
        mapper: services.mapper,
        fixPlanStore: services.planStore,
        runRecordStore: services.runStore
    ))
    let syncService = LibrarySyncService(
        trackStore: services.store,
        cache: services.cache,
        runtimeConfiguration: LibrarySyncRuntimeConfiguration(configuration: configuration),
        observer: services.observer
    )
    let orchestrator = dependencies.makeRunOrchestrator(
        syncService: syncService,
        runRecordStore: services.runStore,
        processor: processor,
        runtimeFactory: services.runtime
    )
    await dependencies.installTestOrchestrator(orchestrator)
    return CompositionFixture(
        dependencies: dependencies,
        runStore: services.runStore,
        script: services.script,
        tracker: tracker,
        directory: directory,
        runtime: services.runtime,
        store: services.store
    )
}

@MainActor
private func makeCompositionServices(
    track: Track,
    discogsAccess: DiscogsAccessStore
) async throws -> CompositionServices {
    let script = RuntimeScriptSpy(track: track)
    let container = try ModelContainerFactory.createInMemory()
    let store = TrackDataStore(modelContainer: container)
    try await store.initialize()
    try await store.seedMirror([track])
    let cache = try GRDBCacheService.createInMemory()
    try await cache.initialize()
    let mapper = TrackIDMapper()
    await mapper.seedKnownMappings([(musicKitTrack: track, appleScriptTrack: track)])
    return CompositionServices(
        script: script,
        observer: MusicAppTestObserver(tracks: [track]),
        store: store,
        planStore: FixPlanDataStore(modelContainer: container),
        runStore: RunRecordDataStore(modelContainer: container),
        cache: cache,
        gate: FeatureGate(fixedTier: .pro),
        undo: UndoCoordinator(musicApp: script),
        mapper: mapper,
        discogsAccess: discogsAccess
    )
}

private actor RuntimeConfigProbe {
    private(set) var last: AppConfiguration?

    func record(_ configuration: AppConfiguration) {
        last = configuration
    }
}

private actor RuntimeScriptSpy: MusicAppIdentifying, MusicAppMutating, MusicAppVerifying {
    private var tracks: [String: Track]
    private(set) var metadataFetches: [[MusicDatabaseTrackID]] = []
    private(set) var batchCalls: [[MusicTrackUpdate]] = []

    init(track: Track) {
        tracks = [track.id: track]
    }

    func fetchMetadata(for databaseIDs: [MusicDatabaseTrackID]) async throws -> [Track] {
        metadataFetches.append(databaseIDs)
        return databaseIDs.compactMap { tracks[$0.rawValue] }
    }

    func fetchIdentityMetadata(scopedTo artists: [String]) async throws -> [Track] {
        ArtistAllowList.filter(Array(tracks.values), allowedArtists: artists)
    }

    func update(
        _ update: MusicTrackUpdate,
        onAttempt: @escaping WriteAttemptHook
    ) async throws -> MusicWriteResult {
        apply(
            property: update.property,
            value: update.value,
            databaseID: update.databaseID.rawValue
        )
        try await onAttempt()
        return .changed
    }

    func update(
        _ updates: [MusicTrackUpdate],
        onAttempt: @escaping WriteAttemptHook
    ) async throws {
        batchCalls.append(updates)
        for update in updates {
            apply(
                property: update.property,
                value: update.value,
                databaseID: update.databaseID.rawValue
            )
        }
        try await onAttempt()
    }

    func storedTrack(id: String) -> Track? {
        tracks[id]
    }

    private func apply(property: MusicTrackProperty, value: String, databaseID: String) {
        guard var track = tracks[databaseID] else { return }
        switch property {
        case .genre:
            track.genre = value
        case .year:
            track.year = Int(value)
        case .name, .album, .artist, .albumArtist:
            break
        }
        tracks[databaseID] = track
    }
}
