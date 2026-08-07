import Core
import Foundation
import OSLog
import Services
import SwiftData
import SwiftUI

private let log = AppLogger.make(category: "dependencies")
private let configurationSaveErrorPrefix = "Failed to save configuration:"

// MARK: - App State

/// Represents the current state of the application.
enum AppState {
    case loading
    case needsOnboarding
    case ready
    case error(String)
}

/// Initialization failures that must keep the app out of the ready state.
enum AppInitializationError: LocalizedError {
    case missingWorkflowPrerequisites([String])

    var errorDescription: String? {
        switch self {
        case let .missingWorkflowPrerequisites(names):
            "Cannot initialize workflow services — missing: \(names.joined(separator: ", "))"
        }
    }
}

// MARK: - App Dependencies

/// Central dependency container and app state manager.
///
/// Owns all service instances and manages initialization order.
/// Injected via `.environment()` to make services available throughout the view hierarchy.
///
/// ## Initialization Order
/// 1. Load configuration
/// 2. Check script installation status
/// 3. If scripts installed → ready; else → onboarding
@Observable
@MainActor
final class AppDependencies {
    // MARK: - Observable State

    private(set) var appState: AppState = .loading
    /// Serialized runtime-apply chain; see `enqueueRuntimeApplyAndPublish`.
    var runtimeApplyQueue: Task<Void, Never>?
    /// Observable mirror of the chrome projection's command descriptors so
    /// SwiftUI Commands scenes re-evaluate; written only by
    /// `refreshChromeProjection()` (slice 10 relocates this).
    var chromeCommands: [ChromeCommandDescriptor] = []
    var config: AppConfiguration
    var isAutoSyncRunning = false
    @ObservationIgnored let projectionStore = ProjectionStore()
    private(set) var configurationLoadIssue: String?
    @ObservationIgnored private let configurationSaver: (AppConfiguration) throws -> Void
    @ObservationIgnored private var configurationSaveRecoveryState: AppState?

    // MARK: - Services (lazy, initialized in initialize())

    private(set) var scriptInstaller: ScriptInstaller?
    private(set) var musicReader: MusicLibraryReader?
    private(set) var libraryReadProvider: (any LibraryReadProvider)?
    private(set) var applescriptBridge: AppleScriptBridge?
    /// Client used to re-read attempted work during recovery clearance;
    /// production wiring points it at the AppleScript bridge.
    private(set) var recoveryObservationClient: (any AppleScriptClient)?
    /// Availability probe consulted before recovery observation so a blocked
    /// environment surfaces an actionable reason instead of a generic failure.
    private(set) var recoveryAvailability: RecoveryAvailability?
    private(set) var subscriptionService: SubscriptionService?
    private(set) var featureGate: FeatureGate?
    private(set) var networkReachabilityMonitor: NetworkReachabilityMonitor?
    private(set) var apiOrchestrator: APIOrchestrator?
    private(set) var pendingVerificationService: (any PendingVerificationService)?
    private(set) var cacheService: GRDBCacheService?
    private(set) var trackStore: TrackDataStore?
    private(set) var changeLogStore: ChangeLogDataStore?
    private(set) var modelContainer: ModelContainer?
    private(set) var genreDeterminator: GenreDeterminator?
    private(set) var yearDeterminator: YearDeterminator?
    private(set) var updateCoordinator: UpdateCoordinator?
    private(set) var batchProcessor: BatchProcessor?
    private(set) var undoCoordinator: UndoCoordinator?
    private(set) var trackIDMapper: TrackIDMapper?
    private(set) var checkpointManager: CheckpointManager?
    private(set) var librarySyncService: LibrarySyncService?
    private(set) var runOrchestrator: RunOrchestrator?
    @ObservationIgnored let discogsAccessStore = DiscogsAccessStore()
    private(set) var runRecordStore: (any RunRecordStore)?
    private(set) var fixPlanStore: (any FixPlanStore)?
    private(set) var librarySnapshotService: (any LibrarySnapshotService)?
    private(set) var analyticsService: CachedAnalyticsService?
    private(set) var maintenanceCoordinator: MaintenanceCoordinator?
    var maintenancePreflightResult: MaintenancePreflightResult?
    private(set) var changePreviewPipeline: ChangePreviewPipeline?
    private(set) var incrementalRunTracker: IncrementalRunTracker?
    @ObservationIgnored private(set) var previousIncrementalScopeTracks: [Track] = []
    private(set) var discogsCredentialIssue: DiscogsCredentialIssue?
    private(set) var isDiscogsAccessAvailable: Bool?
    @ObservationIgnored var trackCountSource: (@Sendable () async -> Int?)?
    @ObservationIgnored var recoveryClearTasks: [UUID: Task<Void, Error>] = [:]

    func setDiscogsIssue(_ issue: DiscogsCredentialIssue?) {
        discogsCredentialIssue = issue
        isDiscogsAccessAvailable = issue == nil
    }

    // MARK: - Init

    init(
        configurationLoader: () throws -> AppConfiguration = AppConfiguration.load,
        configurationSaver: @escaping (AppConfiguration) throws -> Void = { try $0.save() }
    ) {
        self.configurationSaver = configurationSaver

        do {
            config = try configurationLoader()
        } catch {
            let message = "Failed to load configuration: \(error.localizedDescription)"
            config = AppConfiguration()
            configurationLoadIssue = message
            appState = .error(message)
            log.error("\(message, privacy: .public)")
        }

        // Create ModelContainer eagerly so SwiftUI can attach .modelContainer() immediately.
        // ModelContainerFactory.create() is synchronous.
        do {
            modelContainer = try ModelContainerFactory.create()
        } catch {
            log.error("Failed to create ModelContainer in init: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    /// Initialize all services and determine app state.
    ///
    /// Called once from the app's `.task` modifier on launch.
    func initialize() async {
        if let configurationLoadIssue {
            appState = .error(configurationLoadIssue)
            await publishSettingsProjection()
            await refreshChromeProjection()
            return
        }

        migrateDefaultUpdateBehaviorIfNeeded()
        // Bootstrap the settings projection so the store never serves the
        // `.empty` default state once the app is running. A migration
        // persist failure is not fatal (the key is kept for a retry next
        // launch), but its message must survive into the projection —
        // appState is about to become .loading.
        await publishSettingsProjection(saveErrorMessage: configurationSaveErrorMessage)
        await refreshChromeProjection()
        appState = .loading

        do {
            // Step 1: Create script installer
            let installer = try ScriptInstaller()
            scriptInstaller = installer

            // Step 2: Install or refresh bundled scripts when the Application Scripts copy is missing or stale.
            if await !installer.areScriptsCurrent() {
                let installedScripts = try await installer.installScripts()
                log.info("Installed or refreshed \(installedScripts.count, privacy: .public) AppleScript files")
            }

            guard await installer.areScriptsCurrent() else {
                log.info("Scripts are not current after refresh attempt — showing onboarding")
                appState = .needsOnboarding
                return
            }

            // Step 3: Initialize services
            let bridge = AppleScriptBridge(
                installer: installer,
                config: config.applescript,
                libraryPath: config.paths.musicLibraryPath
            )
            try await bridge.initialize()
            applescriptBridge = bridge
            recoveryObservationClient = bridge
            recoveryAvailability = RecoveryAvailability(checks: .live(installer: installer))

            let reader = MusicLibraryReader(
                testArtists: config.development.testArtists
            )
            musicReader = reader
            libraryReadProvider = MusicKitReadProvider(reader: reader)

            // Step 4: Start subscription service + feature gate
            let subscription = SubscriptionService()
            await subscription.start()
            subscriptionService = subscription

            #if DEBUG
            let gate = FeatureGate(fixedTier: .pro)
            log.info("DEBUG: FeatureGate set to .pro (all features unlocked)")
            #else
            let gate = FeatureGate(
                tierProvider: { [weak subscription] in subscription?.currentTier ?? .free },
                freeTracksUsedProvider: { [weak subscription] in subscription?.freeTracksUsed ?? 0 }
            )
            #endif
            featureGate = gate

            // Steps 5-8: Persistence, algorithms, API, and workflow services
            try await initializePersistence()
            try await initializeAlgorithmsAndAPI()
            try await initializeWorkflowServices(bridge: bridge, gate: gate)

            log.info("All services initialized successfully")
            appState = .ready
            // Republish chrome now that every probed fact exists — the
            // bootstrap publish above ran before services were built, and
            // a fresh session emits no lifecycle event to re-derive it.
            await refreshChromeProjection()
        } catch {
            log.error("Initialization failed: \(error.localizedDescription, privacy: .public)")
            appState = .error(error.localizedDescription)
        }
    }

    /// Called when onboarding completes script installation.
    func onboardingComplete() async {
        log.info("Onboarding complete — reinitializing")
        await initialize()
    }

    func replacePreviousIncrementalScopeTracks(_ tracks: [Track]) {
        previousIncrementalScopeTracks = tracks
    }

    // Refresh library data (triggered by Cmd+R).

    /// Surfaces a corrupted-persistence condition that blocks every future
    /// settings mutation; called from the command choke point, where the
    /// fire-and-settle dispatch sites cannot show the message themselves.
    func reportSettingsRevisionCorruption(_ message: String) {
        appState = .error(message)
    }

    /// Persists the configuration WITHOUT applying runtime effects — the
    /// settings command path owns the apply after this succeeds.
    /// An explicit successful save also repairs a failed initial load: the
    /// user has consciously accepted the current values.
    @discardableResult
    func persistConfiguration() -> Bool {
        do {
            try configurationSaver(config)
            configurationLoadIssue = nil
            clearConfigurationSaveIssue()
            // The persisted config carries the current defaultUpdateBehavior,
            // so any pending legacy-key migration is superseded: a stale key
            // must not overwrite a newer explicit choice on the next launch.
            UserDefaults.standard.removeObject(forKey: AppStorageKey.defaultUpdateBehavior)
            return true
        } catch {
            let message = "\(configurationSaveErrorPrefix) \(error.localizedDescription)"
            log.error("\(message, privacy: .public)")
            rememberConfigurationSaveRecoveryState()
            appState = .error(message)
            return false
        }
    }

    private func rememberConfigurationSaveRecoveryState() {
        guard !isConfigurationSaveIssue(appState) else {
            return
        }
        configurationSaveRecoveryState = appState
    }

    private func clearConfigurationSaveIssue() {
        guard isConfigurationSaveIssue(appState) else {
            return
        }
        appState = configurationSaveRecoveryState ?? .ready
        configurationSaveRecoveryState = nil
    }

    func isConfigurationSaveIssue(_ state: AppState) -> Bool {
        guard case let .error(message) = state else {
            return false
        }
        return message.hasPrefix(configurationSaveErrorPrefix)
    }

    // MARK: - Initialization Helpers

    /// Step 5: Set up SwiftData and GRDB persistence layers.
    private func initializePersistence() async throws {
        let container: ModelContainer
        if let existing = modelContainer {
            container = existing
        } else {
            container = try ModelContainerFactory.create()
            modelContainer = container
        }

        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        trackStore = store

        let logStore = ChangeLogDataStore(modelContainer: container)
        changeLogStore = logStore

        runRecordStore = RunRecordDataStore(modelContainer: container)
        fixPlanStore = FixPlanDataStore(modelContainer: container)

        let cache = try GRDBCacheService.createDefault(
            defaultGenericTTL: Self.defaultGenericCacheTTL(configuration: config),
            apiResultTTL: Self.apiResultCacheTTL(configuration: config),
            maxGenericEntries: config.runtime.maxGenericEntries,
            cleanupInterval: TimeInterval(config.caching.cleanupIntervalSeconds)
        )
        try await cache.initialize()
        cacheService = cache
        librarySnapshotService = Self.makeSnapshotService(cache: cache, configuration: config)
        analyticsService = CachedAnalyticsService(
            cache: cache,
            configuration: config.analytics
        )
    }

    private static func defaultGenericCacheTTL(configuration: AppConfiguration) -> TimeInterval {
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

    static func makeYearDeterminator(configuration: AppConfiguration) -> YearDeterminator {
        let yearRetrieval = configuration.yearRetrieval
        return YearDeterminator(
            scorer: YearScorer(
                config: yearRetrieval.scoring,
                yearLogic: yearRetrieval.logic,
                editionKeywords: configuration.cleaning.remasterKeywords
            ),
            validator: YearValidator(config: yearRetrieval.logic),
            fallback: YearFallbackStrategy(
                config: yearRetrieval.fallback,
                yearLogic: yearRetrieval.logic
            ),
            processingConfig: configuration.processing
        )
    }

    /// Steps 6-7: Create core algorithm instances and API orchestrator.
    private func initializeAlgorithmsAndAPI() async throws {
        let genreDeterm = GenreDeterminator()
        genreDeterminator = genreDeterm

        let yearDeterm = Self.makeYearDeterminator(configuration: config)
        yearDeterminator = yearDeterm

        guard let container = modelContainer else {
            throw DependencySetupError.missingModelContainer
        }

        let pendingVerification = PendingVerificationStore(modelContainer: container, configuration: config)
        try await pendingVerification.initialize()
        pendingVerificationService = pendingVerification

        let reachability = NetworkReachabilityMonitor()
        await reachability.start()
        networkReachabilityMonitor = reachability

        apiOrchestrator = Self.makeAPIOrchestrator(
            configuration: config,
            cache: cacheService,
            pendingVerificationService: pendingVerification,
            reachability: reachability,
            factoryOverrides: APIClientFactoryOverrides(discogsCredentialIssueHandler: { [weak self] issue in
                self?.setDiscogsIssue(issue)
            })
        )
    }

    /// Step 8: Wire workflow services that depend on persistence, algorithms, and the script bridge.
    private func initializeWorkflowServices(bridge: AppleScriptBridge, gate: FeatureGate) async throws {
        let checkpoint = CheckpointManager()
        checkpointManager = checkpoint
        incrementalRunTracker = Self.makeIncrementalRunTracker(configuration: config)

        guard let logStore = changeLogStore,
              let store = trackStore,
              let cache = cacheService,
              let orchestrator = apiOrchestrator,
              let genreDeterm = genreDeterminator,
              let yearDeterm = yearDeterminator,
              let recordStore = runRecordStore
        else {
            throw AppInitializationError.missingWorkflowPrerequisites(missingWorkflowPrerequisiteNames())
        }

        let mapper = TrackIDMapper()
        trackIDMapper = mapper

        let undo = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: mapper,
            changeLogStore: logStore,
            cache: cache,
            librarySnapshotService: librarySnapshotService,
            cleaning: config.cleaning
        )
        await undo.initialize()
        undoCoordinator = undo

        updateCoordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                stores: .init(trackStore: store, cache: cache),
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: librarySnapshotService,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: genreDeterm,
            yearDeterminator: yearDeterm,
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: config)
        )

        let processor = makeBatchProcessor(checkpoint: checkpoint, gate: gate)
        batchProcessor = processor

        let syncService = makeLibrarySyncService(
            bridge: bridge,
            store: store,
            gate: gate,
            cache: cache
        )
        librarySyncService = syncService
        runOrchestrator = makeRunOrchestrator(
            syncService: syncService,
            runRecordStore: recordStore,
            processor: processor
        )

        maintenanceCoordinator = MaintenanceCoordinator(
            databaseVerificationService: syncService,
            pendingVerificationService: pendingVerificationService
        )

        changePreviewPipeline = ChangePreviewPipeline()
    }

    private func makeLibrarySyncService(
        bridge: AppleScriptBridge,
        store: any TrackStateStore,
        gate: FeatureGate,
        cache: any CacheService
    ) -> LibrarySyncService {
        LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            pendingVerificationService: pendingVerificationService,
            librarySnapshotService: librarySnapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(configuration: config),
            readProvider: libraryReadProvider
        )
    }

    private func makeBatchProcessor(checkpoint: CheckpointManager, gate: FeatureGate) -> BatchProcessor {
        BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate,
            processingConfiguration: BatchProcessingConfiguration(configuration: config)
        )
    }

    func writeDependencies(
        store: any RunRecordStore,
        processor: BatchProcessor,
        writeFixPlan: (@Sendable (
            FixPlanWriteInput,
            RunID,
            @escaping WorkCheckpointSink
        ) async throws -> BatchUpdateResult)?
    ) -> RunOrchestrator.WriteDependencies {
        RunOrchestrator.WriteDependencies(
            persistCheckpoint: { runID, checkpoint in
                try await store.checkpoint(checkpoint, runID: runID)
            },
            writeFixPlan: writeFixPlan,
            beginRecoveryHold: {
                await processor.beginRecoveryHold()
            },
            restoreRecoveryHold: { id in
                await processor.beginRecoveryHold(id: id)
            },
            clearRecoveryHold: { id in
                try await processor.clearRecovery(batchID: id)
            }
        )
    }

    private func makeRunOrchestrator(
        syncService: LibrarySyncService,
        runRecordStore: any RunRecordStore,
        processor: BatchProcessor
    ) -> RunOrchestrator {
        let runtime = makeRunRuntime()
        let synchronizePreview: (@Sendable (
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> SyncResult)? = if let runtime {
            { scope, configuration in
                let syncService = try await runtime.makeSync(
                    configuration: configuration,
                    scope: scope
                )
                return try await syncService.synchronizeNow()
            }
        } else {
            nil
        }
        let write = writeDependencies(
            store: runRecordStore,
            processor: processor,
            writeFixPlan: makeWriteRunner(runtime: runtime)
        )

        return RunOrchestrator(dependencies: RunOrchestrator.Dependencies(
            synchronizeLibrary: { [syncService] in
                try await syncService.synchronizeNow()
            },
            synchronizePreview: synchronizePreview,
            persistRunRecord: RunRecordSink.make(
                store: runRecordStore,
                // nil after container teardown: the sink skips pruning rather
                // than deleting against a guessed default limit.
                historyLimit: { [weak self] in await self?.runHistoryLimit() },
                pruneFixPlans: { [weak self] in
                    await self?.pruneFixPlans(runRecordStore: runRecordStore)
                }
            ),
            produceFixPlan: makePreviewProducer(runtime: runtime),
            releasePreview: { configuration in
                await runtime?.discard(configuration)
            },
            write: write,
            currentDecisionTarget: makeCurrentDecisionTarget()
        ))
    }

    func refreshFixPlanProjection() async -> FixPlanProjection {
        let inputGeneration = await projectionStore.nextFixPlanInputGeneration()
        let projection: FixPlanProjection
        do {
            projection = try await latestFixPlanProjection()
        } catch {
            projection = .unavailable(message: error.localizedDescription)
        }
        return await projectionStore.replaceFixPlanProjection(
            projection,
            inputGeneration: inputGeneration
        )
    }

    private func latestFixPlanProjection() async throws -> FixPlanProjection {
        guard let fixPlanStore else {
            return .empty()
        }
        guard let plan = try await fixPlanStore.latestPlan() else {
            return .empty()
        }
        guard let decision = try await fixPlanStore.currentDecision(for: plan.id) else {
            return .unavailable(
                message: "Review decision is missing for fix plan \(plan.id.rawValue.uuidString)"
            )
        }

        let now = Date()
        let currentScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: nil,
            createdAt: now,
            reason: "fixPlanProjectionRefresh"
        )
        let currentConfiguration = capturePreviewConfig(
            at: now,
            hasDiscogsAccess: isDiscogsAccessAvailable ?? plan.configuration.hasDiscogsAccess
        )
        return FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: currentScope,
                currentConfiguration: currentConfiguration
            )
        )
    }

    private func runHistoryLimit() -> Int {
        config.reporting.runHistoryLimit
    }

    private func missingWorkflowPrerequisiteNames() -> [String] {
        [
            changeLogStore == nil ? "changeLogStore" : nil,
            trackStore == nil ? "trackStore" : nil,
            cacheService == nil ? "cacheService" : nil,
            apiOrchestrator == nil ? "apiOrchestrator" : nil,
            genreDeterminator == nil ? "genreDeterminator" : nil,
            yearDeterminator == nil ? "yearDeterminator" : nil,
            runRecordStore == nil ? "runRecordStore" : nil
        ].compactMap(\.self)
    }
}

extension AppDependencies {
    func applyRuntimeConfigurationHead() -> RuntimeApplyHandoff {
        let configuredYearDeterminator = Self.makeYearDeterminator(configuration: config)
        incrementalRunTracker = Self.makeIncrementalRunTracker(configuration: config)
        let pendingVerificationStore = modelContainer.map {
            PendingVerificationStore(modelContainer: $0, configuration: config)
        }
        let configuredAPIOrchestrator = Self.makeAPIOrchestrator(
            configuration: config,
            cache: cacheService,
            pendingVerificationService: pendingVerificationStore,
            reachability: networkReachabilityMonitor,
            factoryOverrides: APIClientFactoryOverrides(discogsCredentialIssueHandler: { [weak self] issue in
                self?.setDiscogsIssue(issue)
            })
        )
        yearDeterminator = configuredYearDeterminator
        pendingVerificationService = pendingVerificationStore
        apiOrchestrator = configuredAPIOrchestrator
        if let librarySyncService {
            maintenanceCoordinator = MaintenanceCoordinator(
                databaseVerificationService: librarySyncService,
                pendingVerificationService: pendingVerificationStore
            )
        }
        let snapshotService: (any LibrarySnapshotService)?
        if let cacheService {
            let newSnapshotService = Self.makeSnapshotService(cache: cacheService, configuration: config)
            librarySnapshotService = newSnapshotService
            snapshotService = newSnapshotService
            analyticsService = CachedAnalyticsService(
                cache: cacheService,
                configuration: config.analytics
            )
        } else {
            snapshotService = nil
        }

        return RuntimeApplyHandoff(
            pendingVerificationStore: pendingVerificationStore,
            snapshotService: snapshotService,
            yearDeterminator: configuredYearDeterminator,
            apiOrchestrator: configuredAPIOrchestrator,
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: config),
            appleScriptConfiguration: config.applescript,
            librarySyncRuntimeConfiguration: LibrarySyncRuntimeConfiguration(configuration: config),
            batchProcessingConfiguration: BatchProcessingConfiguration(configuration: config),
            libraryPath: config.paths.musicLibraryPath,
            testArtists: config.development.testArtists,
            analytics: config.analytics,
            cleaning: config.cleaning
        )
    }

    static func makeSnapshotService(
        cache: any CacheService,
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

    private static func makeIncrementalRunTracker(configuration: AppConfiguration) -> IncrementalRunTracker {
        IncrementalRunTracker(
            logsBaseDirectory: configuration.paths.effectiveLogsBaseDirectory,
            lastIncrementalRunFile: configuration.logging.lastIncrementalRunFile
        )
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

#if DEBUG
extension AppDependencies {
    func installTestWrites(_ services: TestWriteServices) {
        batchProcessor = services.batchProcessor
        undoCoordinator = services.undoCoordinator
        updateCoordinator = services.updateCoordinator
        trackIDMapper = services.mapper
        fixPlanStore = services.fixPlanStore
        runRecordStore = services.runRecordStore
    }

    func configureLibraryPersistenceForTesting(
        trackStore: TrackDataStore? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        runRecordStore: (any RunRecordStore)? = nil,
        fixPlanStore: (any FixPlanStore)? = nil
    ) {
        self.trackStore = trackStore
        self.librarySnapshotService = librarySnapshotService
        self.runRecordStore = runRecordStore
        self.fixPlanStore = fixPlanStore
    }

    func installTestOrchestrator(_ orchestrator: RunOrchestrator) {
        runOrchestrator = orchestrator
    }

    func installTestObservationClient(_ client: any AppleScriptClient) {
        recoveryObservationClient = client
    }

    func installTestAvailability(_ availability: RecoveryAvailability) {
        recoveryAvailability = availability
    }

    func installTrackCountSource(_ source: @escaping @Sendable () async -> Int?) {
        trackCountSource = source
    }
}
#endif
