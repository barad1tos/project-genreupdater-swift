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
    let analytics: (any AnalyticsService)?

    @MainActor
    func makeSync(
        configuration: FixPlanConfig,
        scope: ProcessingScopeSnapshot
    ) async throws -> LibrarySyncService {
        let appConfiguration = try scopedConfiguration(
            configuration.appConfiguration,
            scope: scope
        )
        let cacheConfiguration = cacheConfiguration(for: appConfiguration)
        let runServices = try await services.prepareObservation(
            id: configuration.id,
            configuration: appConfiguration
        )
        return try LibrarySyncService(
            trackStore: store,
            cache: cache,
            pendingVerificationService: runServices.pendingVerification,
            librarySnapshotService: AppDependencies.makeSnapshotService(
                cache: cache,
                configuration: cacheConfiguration
            ),
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                configuration: appConfiguration,
                capturedScope: scope
            ),
            observer: runServices.observer
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
        let runServices = try await services.consumePreview(
            id: configuration.id,
            configuration: appConfiguration
        )
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: cacheConfiguration
        )
        let capturedAccess = try await discogsAccess(for: configuration)
        let apiOrchestrator = AppDependencies.makeCapturedAPI(
            configuration: cacheConfiguration,
            cache: cache,
            reachability: reachability,
            discogsAccess: capturedAccess,
            analytics: analytics
        )
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: apiOrchestrator,
                stores: .init(
                    trackStore: store,
                    cache: cache
                ),
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: snapshotService,
                pendingVerificationService: runServices.pendingVerification,
                analytics: analytics
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: AppDependencies.makeYearDeterminator(configuration: appConfiguration),
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: appConfiguration)
        )
        let identity = WriteIdentityRefresher(mapper: mapper, source: runServices.identifier)

        return FixPlanProducer.Runtime(
            refreshIdentity: { tracks, currentScope in
                try await identity.refresh(
                    tracks: tracks,
                    scope: currentScope
                )
            },
            albumContext: { await coordinator.albumContextTracksByTrackID(for: $0, requiresMutationMetadata: false) },
            artistContext: { await coordinator.artistContextTracksByTrackID(for: $0) },
            determineChanges: {
                try await coordinator.updateTrack(
                    $0,
                    albumTracks: $1,
                    artistTracks: $2,
                    options: $3,
                    dryRun: true,
                    yearRunScope: $4
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
        let runServices = try await services.consumeWrite(
            id: configuration.id,
            configuration: appConfiguration
        )
        let snapshotService = AppDependencies.makeSnapshotService(
            cache: cache,
            configuration: cacheConfiguration
        )
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: AppDependencies.makeCapturedAPI(
                    configuration: cacheConfiguration,
                    cache: cache,
                    reachability: reachability,
                    discogsAccess: .disabled,
                    analytics: analytics
                ),
                writer: runServices.writer,
                stores: .init(trackStore: store, cache: cache),
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: snapshotService,
                pendingVerificationService: runServices.pendingVerification,
                analytics: analytics
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: AppDependencies.makeYearDeterminator(configuration: appConfiguration),
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: appConfiguration)
        )
        return FixPlanWrite.Runtime(coordinator: coordinator, verifier: runServices.writer)
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
        scoped.development.testArtists = targetedArtistScope(scope: scope, albumTarget: albumTarget)
        try scoped.validate()
        return scoped
    }

    /// A one-album preview or write inside a test-artist scope narrows its
    /// runtime context to the target artist without widening the submitted
    /// scope. Full-library runs retain their empty allow-list; album identity
    /// remains a plan-level selection concern. Unknown or out-of-scope target
    /// artists fall back to the submitted scope.
    func targetedArtistScope(
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
    let source: any MusicAppIdentifying

    func refresh(
        tracks: [Track],
        scope: ProcessingScopeSnapshot
    ) async throws {
        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: tracks,
            identitySource: source,
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
              let mapper = trackIDMapper,
              let analytics = analyticsService
        else {
            return nil
        }

        return RunRuntimeFactory(
            services: RunServiceFactory(
                makeMusicAccess: { configuration in
                    let bridge = AppleScriptBridge(
                        installer: installer,
                        config: configuration.applescript,
                        libraryPath: configuration.paths.musicLibraryPath,
                        analytics: analytics
                    )
                    try await bridge.initialize()
                    return RunMusicAccess(
                        identifier: bridge,
                        writer: bridge,
                        observer: MusicAppObserver(bridge: bridge)
                    )
                },
                makePendingVerification: { configuration in
                    let pendingVerification = PendingVerificationStore(
                        modelContainer: container,
                        configuration: configuration
                    )
                    try await pendingVerification.initialize()
                    return pendingVerification
                }
            ),
            store: store,
            gate: gate,
            cache: cache,
            undo: undo,
            mapper: mapper,
            reachability: networkReachabilityMonitor,
            discogsAccessStore: discogsAccessStore,
            analytics: analytics
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
