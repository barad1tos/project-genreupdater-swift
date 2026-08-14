import Core
import Foundation
import OSLog
import Services

private let runRuntimeLog = Logger(subsystem: "com.genreupdater", category: "run-runtime")

struct RunRuntimeFactory {
    let services: RunServiceFactory
    let store: any TrackStateStore
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
        let appConfiguration = try scopedConfiguration(
            configuration.appConfiguration,
            scope: scope,
            albumTarget: configuration.albumTarget
        )
        let cacheConfiguration = cacheConfiguration(for: appConfiguration)
        let runServices = try await services.prepare(id: configuration.id, configuration: appConfiguration)
        return LibrarySyncService(
            scriptBridge: runServices.scripts,
            trackStore: store,
            cache: cache,
            pendingVerificationService: runServices.pendingVerification,
            librarySnapshotService: AppDependencies.makeSnapshotService(
                cache: cache,
                configuration: cacheConfiguration
            ),
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                configuration: appConfiguration,
                albumTargetIdentity: configuration.albumTarget.map {
                    AlbumIdentity(artist: $0.artist, album: $0.album)
                }
            ),
            readProvider: runServices.readProvider
        )
    }

    @MainActor
    func makePreview(
        configuration: FixPlanConfig,
        scope: ProcessingScopeSnapshot
    ) async throws -> FixPlanProducer.Runtime {
        let appConfiguration = try scopedConfiguration(
            configuration.appConfiguration,
            scope: scope,
            albumTarget: configuration.albumTarget
        )
        let cacheConfiguration = cacheConfiguration(for: appConfiguration)
        let runServices = try await services.consume(id: configuration.id, configuration: appConfiguration)
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: cacheConfiguration
        )
        let capturedAccess = try await discogsAccess(for: configuration)
        let apiOrchestrator = AppDependencies.makeCapturedAPI(
            configuration: cacheConfiguration,
            cache: cache,
            pendingVerificationService: runServices.pendingVerification,
            reachability: reachability,
            discogsAccess: capturedAccess
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
        let appConfiguration = try scopedConfiguration(
            configuration.appConfiguration,
            scope: scope,
            albumTarget: configuration.albumTarget
        )
        let cacheConfiguration = cacheConfiguration(for: appConfiguration)
        let runServices = try await services.consume(id: configuration.id, configuration: appConfiguration)
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: cacheConfiguration
        )
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: AppDependencies.makeCapturedAPI(
                    configuration: cacheConfiguration,
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

    @MainActor
    func cacheConfiguration(for configuration: AppConfiguration) -> AppConfiguration {
        AppDependencies.effectiveCacheConfiguration(
            configuration,
            canUseAdvancedCache: gate.canAccess(.advancedCache)
        )
    }

    private func discogsAccess(for configuration: FixPlanConfig) async throws -> DiscogsAccess {
        let access = await discogsAccessStore.consume(configurationID: configuration.id)
        guard !configuration.hasDiscogsAccess || access != nil else {
            throw RunRuntimeError.missingDiscogsAccess
        }
        return access ?? .disabled
    }

    private func scopedConfiguration(
        _ configuration: AppConfiguration,
        scope: ProcessingScopeSnapshot,
        albumTarget: FixPlanAlbumTarget? = nil
    ) throws -> AppConfiguration {
        var scoped = configuration
        scoped.development.testArtists = syncArtistScope(scope: scope, albumTarget: albumTarget)
        try scoped.validate()
        return scoped
    }

    /// A one-album preview inside a test-artist scope narrows the sync
    /// READ to the target's artist — a strict subset of the scope's own
    /// allow-list semantics, so no track the scope admitted is lost.
    /// The FULL-LIBRARY case narrows through the read request's ALBUM
    /// IDENTITY instead (makeSync passes it): the admission predicate
    /// admits collaboration spellings via lookup aliases, which artist
    /// strings never could. In the scoped case both mechanisms apply and
    /// the allow-list stays the stricter gate (never widen). Empty or
    /// unknown target artists and out-of-scope targets fail OPEN to the
    /// scope: never widen, never guess.
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
    static func makeSnapshotService(
        cache: any PersistentCacheService,
        configuration: AppConfiguration
    ) -> CachedLibrarySnapshotService {
        CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration.caching.librarySnapshot,
            libraryModificationDateProvider: makeLibraryDateProvider(
                path: configuration.paths.musicLibraryPath
            )
        )
    }

    static func effectiveCacheConfiguration(
        _ configuration: AppConfiguration,
        canUseAdvancedCache: Bool
    ) -> AppConfiguration {
        guard !canUseAdvancedCache else {
            return configuration
        }

        let defaults = AppConfiguration()
        var effective = configuration
        effective.caching = defaults.caching
        effective.runtime.cacheTTLSeconds = defaults.runtime.cacheTTLSeconds
        effective.runtime.maxGenericEntries = defaults.runtime.maxGenericEntries
        effective.processing.cacheTTLDays = defaults.processing.cacheTTLDays
        return effective
    }

    static func apiResultCacheTTL(configuration: AppConfiguration) -> TimeInterval {
        GRDBCacheService.resolvedAPIResultTTL(configuration: configuration)
    }

    private static func makeLibraryDateProvider(path: String) -> @Sendable () -> Date? {
        let resolvedPath = resolveConfigurationPath(path)
        return {
            guard !resolvedPath.isEmpty else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
            return attributes?[.modificationDate] as? Date
        }
    }

    private static func resolveConfigurationPath(_ path: String) -> String {
        var resolvedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPath.isEmpty else { return "" }

        resolvedPath = resolvedPath.replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
        let appSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        if resolvedPath.contains("${APP_SUPPORT}"), let appSupportDirectory {
            resolvedPath = resolvedPath.replacingOccurrences(
                of: "${APP_SUPPORT}",
                with: appSupportDirectory.appendingPathComponent("GenreUpdater", isDirectory: true).path
            )
        }

        return (resolvedPath as NSString).expandingTildeInPath
    }
}
