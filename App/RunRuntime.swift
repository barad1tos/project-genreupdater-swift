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
        let appConfiguration = scopedConfiguration(configuration.appConfiguration, scope: scope)
        let runServices = try await services.prepare(id: configuration.id, configuration: appConfiguration)
        return LibrarySyncService(
            scriptBridge: runServices.scripts,
            trackStore: store,
            featureGate: gate,
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
        let appConfiguration = scopedConfiguration(configuration.appConfiguration, scope: scope)
        let runServices = try await services.consume(id: configuration.id, configuration: appConfiguration)
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: appConfiguration
        )
        let capturedAccess = await discogsAccessStore.consume(configurationID: configuration.id)
        guard !configuration.hasDiscogsAccess || capturedAccess != nil else {
            throw RunRuntimeError.missingDiscogsAccess
        }
        let apiOrchestrator = AppDependencies.makePreviewAPIOrchestrator(
            configuration: appConfiguration,
            cache: cache,
            pendingVerificationService: runServices.pendingVerification,
            reachability: reachability,
            discogsAccess: capturedAccess ?? .disabled
        )
        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: apiOrchestrator,
                scriptBridge: runServices.scripts,
                trackStore: store,
                cache: cache,
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

    func discard(_ configuration: FixPlanConfig) async {
        await services.discard(id: configuration.id)
        await discogsAccessStore.discard(configurationID: configuration.id)
    }

    private func scopedConfiguration(
        _ configuration: AppConfiguration,
        scope: ProcessingScopeSnapshot
    ) -> AppConfiguration {
        var scoped = configuration
        scoped.development.testArtists = scope.normalizedTestArtists
        return scoped
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
