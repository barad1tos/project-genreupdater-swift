import Core
import Foundation
import OSLog
import Services

private let runRuntimeLog = Logger(subsystem: "com.genreupdater", category: "run-runtime")

struct RunRuntimeFactory {
    let services: RunServiceFactory
    let store: TrackDataStore
    let gate: FeatureGate
    let cache: GRDBCacheService
    let undo: UndoCoordinator
    let mapper: TrackIDMapper
    let reachability: NetworkReachabilityMonitor?
    let discogsAccessStore: DiscogsAccessStore

    @MainActor
    func makeSync(
        configuration: FixPlanConfig,
        scope: ProcessingScopeSnapshot
    ) async throws -> LibrarySyncService {
        let appConfiguration = scopedConfiguration(
            configuration.appConfiguration,
            scope: scope,
            albumTarget: configuration.albumTarget
        )
        let runServices = try await services.prepare(id: configuration.id, configuration: appConfiguration)
        return LibrarySyncService(
            scriptBridge: runServices.scripts,
            trackStore: store,
            cache: cache,
            pendingVerificationService: runServices.pendingVerification,
            librarySnapshotService: AppDependencies.makeSnapshotService(
                cache: cache,
                configuration: appConfiguration
            ),
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(configuration: appConfiguration),
            readProvider: runServices.readProvider
        )
    }

    @MainActor
    func makePreview(
        configuration: FixPlanConfig,
        scope: ProcessingScopeSnapshot
    ) async throws -> FixPlanProducer.Runtime {
        let appConfiguration = scopedConfiguration(
            configuration.appConfiguration,
            scope: scope,
            albumTarget: configuration.albumTarget
        )
        let runServices = try await services.consume(id: configuration.id, configuration: appConfiguration)
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: appConfiguration
        )
        let capturedAccess = await discogsAccessStore.consume(configurationID: configuration.id)
        guard !configuration.hasDiscogsAccess || capturedAccess != nil else {
            throw RunRuntimeError.missingDiscogsAccess
        }
        let apiOrchestrator = AppDependencies.makeCapturedAPI(
            configuration: appConfiguration,
            cache: cache,
            pendingVerificationService: runServices.pendingVerification,
            reachability: reachability,
            discogsAccess: capturedAccess ?? .disabled
        )
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: apiOrchestrator,
                scriptBridge: runServices.scripts,
                stores: .init(
                    trackStore: store,
                    cache: cache
                ),
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: snapshotService,
                pendingVerificationService: runServices.pendingVerification
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: AppDependencies.makeYearDeterminator(configuration: appConfiguration),
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: appConfiguration)
        )
        let identity = WriteIdentityRefresher(mapper: mapper, client: runServices.scripts)

        return FixPlanProducer.Runtime(
            refreshIdentity: { tracks, currentScope in
                try await identity.refresh(
                    tracks: tracks,
                    scope: currentScope,
                    config: appConfiguration.applescript
                )
            },
            albumContext: {
                await coordinator.albumContextTracksByTrackID(for: $0, requiresMutationMetadata: false)
            },
            determineChanges: {
                try await coordinator.updateTrack(
                    $0,
                    albumTracks: $1,
                    artistTracks: $2,
                    options: $3,
                    dryRun: true
                )
            }
        )
    }

    @MainActor
    func makeWrite(
        configuration: FixPlanConfig,
        scope: ProcessingScopeSnapshot
    ) async throws -> FixPlanWrite.Runtime {
        let appConfiguration = scopedConfiguration(
            configuration.appConfiguration,
            scope: scope,
            albumTarget: configuration.albumTarget
        )
        let runServices = try await services.consume(id: configuration.id, configuration: appConfiguration)
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: appConfiguration
        )
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: AppDependencies.makeCapturedAPI(
                    configuration: appConfiguration,
                    cache: cache,
                    pendingVerificationService: runServices.pendingVerification,
                    reachability: reachability,
                    discogsAccess: .disabled
                ),
                scriptBridge: runServices.scripts,
                stores: .init(trackStore: store, cache: cache),
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: snapshotService,
                pendingVerificationService: runServices.pendingVerification
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: AppDependencies.makeYearDeterminator(configuration: appConfiguration),
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: appConfiguration)
        )
        return FixPlanWrite.Runtime(coordinator: coordinator, scripts: runServices.scripts)
    }

    func discard(_ configuration: FixPlanConfig) async {
        await services.discard(id: configuration.id)
        await discogsAccessStore.discard(configurationID: configuration.id)
    }

    private func scopedConfiguration(
        _ configuration: AppConfiguration,
        scope: ProcessingScopeSnapshot,
        albumTarget: FixPlanAlbumTarget? = nil
    ) -> AppConfiguration {
        var scoped = configuration
        scoped.development.testArtists = syncArtistScope(scope: scope, albumTarget: albumTarget)
        return scoped
    }

    /// A one-album preview inside a test-artist scope narrows the sync
    /// READ to the target's artist — a strict subset of the scope's own
    /// allow-list semantics, so no track the scope admitted is lost.
    /// A FULL-LIBRARY preview must NOT narrow: the empty allow-list
    /// passes every artist spelling, and narrowing it to the browse
    /// node's grouping artist would drop "X feat. Y" tracks at the
    /// coordinator gate (groupingArtist strips the feat suffix,
    /// effectiveArtist keeps it). Identity-aware narrowing for the
    /// full-library case is ledgered. Empty/unknown target artists and
    /// out-of-scope targets fail OPEN to the scope: never widen, never
    /// guess.
    func syncArtistScope(
        scope: ProcessingScopeSnapshot,
        albumTarget: FixPlanAlbumTarget?
    ) -> [String] {
        let scopeArtists = scope.normalizedTestArtists
        guard let albumTarget,
              !scopeArtists.isEmpty,
              ArtistAllowList.normalizedName(albumTarget.artist) != nil,
              ArtistAllowList.containsNormalized(albumTarget.artist, in: scopeArtists)
        else { return scopeArtists }

        return [albumTarget.artist]
    }
}

struct WriteIdentityRefresher {
    let mapper: TrackIDMapper
    let client: any AppleScriptClient

    func refresh(
        tracks: [Track],
        scope: ProcessingScopeSnapshot,
        config: AppleScriptConfig
    ) async throws {
        let trackFetchTimeout = scope.normalizedTestArtists.isEmpty
            ? config.timeouts.idsBatchFetch
            : config.timeouts.singleArtistFetch
        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: tracks,
            appleScriptClient: client,
            batchSize: config.batchProcessing.idsBatchSize,
            allTrackIDsTimeout: config.timeouts.fullLibraryFetch,
            tracksByIDsTimeout: trackFetchTimeout,
            testArtists: scope.normalizedTestArtists,
            mergeExisting: true
        )
        runRuntimeLog.info(
            "Track ID mapping refreshed: \(mappedCount, privacy: .public)/\(tracks.count, privacy: .public)"
        )
    }
}

extension AppDependencies {
    func makeRunRuntime() -> RunRuntimeFactory? {
        guard let installer = scriptInstaller,
              let container = modelContainer,
              let store = trackStore,
              let gate = featureGate,
              let cache = cacheService,
              let undo = undoCoordinator,
              let mapper = trackIDMapper
        else {
            return nil
        }

        return RunRuntimeFactory(
            services: RunServiceFactory(
                makeScripts: { configuration in
                    let bridge = AppleScriptBridge(
                        installer: installer,
                        config: configuration.applescript,
                        libraryPath: configuration.paths.musicLibraryPath
                    )
                    try await bridge.initialize()
                    return bridge
                },
                makePendingVerification: { configuration in
                    let pendingVerification = PendingVerificationStore(
                        modelContainer: container,
                        configuration: configuration
                    )
                    try await pendingVerification.initialize()
                    return pendingVerification
                },
                makeReadProvider: { _ in
                    MusicKitReadProvider(reader: MusicLibraryReader())
                }
            ),
            store: store,
            gate: gate,
            cache: cache,
            undo: undo,
            mapper: mapper,
            reachability: networkReachabilityMonitor,
            discogsAccessStore: discogsAccessStore
        )
    }
}

private enum RunRuntimeError: LocalizedError {
    case missingDiscogsAccess

    var errorDescription: String? {
        "Captured Discogs access is unavailable for this preview run"
    }
}

extension AppDependencies {
    static func defaultGenericCacheTTL(configuration: AppConfiguration) -> TimeInterval {
        let candidates = [
            configuration.caching.defaultTTLSeconds,
            configuration.runtime.cacheTTLSeconds
        ]

        for seconds in candidates where seconds > 0 {
            return TimeInterval(seconds)
        }

        return 5 * 60
    }

    static func apiResultCacheTTL(configuration: AppConfiguration) -> TimeInterval {
        GRDBCacheService.resolvedAPIResultTTL(configuration: configuration)
    }
}
