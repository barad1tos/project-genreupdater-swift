import Core
import Foundation
import OSLog
import Services
import SwiftData
import SwiftUI

private let log = AppLogger.make(category: "dependencies")
private let configurationSaveErrorPrefix = "Failed to save configuration:"

// MARK: - App Dependencies

/// Central dependency container and app state manager; injected via
/// `.environment()` so services are available throughout the hierarchy.
@Observable
@MainActor
final class AppDependencies {
    // MARK: - Observable State

    private(set) var appState: AppState = .loading
    /// Serialized runtime-apply chain; see `enqueueRuntimeApplyAndPublish`.
    var runtimeApplyQueue: Task<Void, Never>?
    @ObservationIgnored var appliedTier: Tier?
    @ObservationIgnored var appliedCacheAccess: Bool?
    /// Chrome mirror for Commands/MenuBarExtra; `refreshChromeProjection()`
    /// is the SOLE publisher (pinned by `oneChromeTruthAcrossSurfaces`).
    var chrome: ChromeProjection = .empty()
    var config: AppConfiguration
    var isAutomationArmed = false
    @ObservationIgnored var cachedBrowseScopeSnapshot: ProcessingScopeSnapshot?
    /// Last observed run boundary; written only by the lifecycle observer.
    @ObservationIgnored var currentLifecycleSnapshot: RunLifecycleSnapshot?
    @ObservationIgnored var lifecycleObserverTask: Task<Void, Never>?
    @ObservationIgnored var lastChromeLifecycleRunID: RunID?
    @ObservationIgnored var lastChromeLifecycleState: RunLifecycleState?
    /// One reload-coordination truth for window, commands, and menus;
    /// producers set it, run completion advances it (D4).
    var queuedManualReload: QueuedManualReload?
    /// Pulled fresh at every publish; nil (no window/VM) reads as
    /// .empty — honest idle instead of a stale cached phase (A8).
    @ObservationIgnored var workflowFactsProvider: (@MainActor () -> ActivityWorkflowFacts)?
    /// Cached tracker read for the sync chrome snapshot (D6); refreshed
    /// at initialize, runtime re-apply, and after a run advances the
    /// tracker. nil = tracker value unavailable (unknown stays unknown).
    @ObservationIgnored var lastIncrementalRunTimestamp: Date?
    /// The live batch executor (D3): registered with the workflow
    /// view-model, consumed by the orchestrator's runner bridge. nil =
    /// no window — a submitted batch fails fast instead of running blind.
    @ObservationIgnored var batchRunProvider: (@MainActor (BatchRunInput, RunID) async throws -> BatchUpdateResult)?
    /// The armed schedule source (ADR 0003); nil = manual/watch-only
    /// strategy or missing Pro access. Re-armed by applyAutomationStrategy.
    @ObservationIgnored var automationScheduleTask: Task<Void, Never>?
    /// The interval the live loop was armed with — identical inputs
    /// short-circuit the re-arm so settings edits never reset the tick.
    @ObservationIgnored var armedScheduleInterval: TimeInterval?
    /// In-memory tick anchor: planning without writes never advances the durable
    /// processing watermark. Successful batch and canonical writes move it, so
    /// re-arms after the first tick anchor here instead of firing immediately on
    /// every settings apply.
    @ObservationIgnored var lastScheduledTickAt: Date?
    /// The armed watch source consumer; nil = strategy without watch,
    /// missing Pro, or an unavailable source (sandbox).
    @ObservationIgnored var automationWatchTask: Task<Void, Never>?
    /// The path the live watch task was armed on (short-circuit parity
    /// with armedScheduleInterval).
    @ObservationIgnored var armedWatchPath: String?
    /// Python launchd ThrottleInterval parity: watch events inside this
    /// window coalesce into the earlier tick.
    @ObservationIgnored var lastWatchTickAt: Date?
    /// Injected library-change source; built lazily from the configured
    /// library path, replaceable in tests.
    @ObservationIgnored var libraryChangeSource: (any LibraryChangeSource)?
    /// The path the self-built watcher was created for; nil for
    /// test-injected stubs (which must never be clobbered). A differing
    /// current path rebuilds the watcher on the next apply.
    @ObservationIgnored var libraryChangeSourceBuiltPath: String?
    /// One idempotent deferred tick per throttle window: launchd defers
    /// a throttled invocation, it never drops it.
    @ObservationIgnored var automationWatchTrailingTask: Task<Void, Never>?
    /// Registration surface for the bundled thin-waker agent; nil until
    /// initialize wires the SMAppService implementation.
    @ObservationIgnored private(set) var agentRegistrar: (any AgentRegistrar)?
    /// A cold-launch agent wake parked until the runtime is armed; the
    /// completeLaunch tail drains it (the pre-arm change would otherwise
    /// be lost — the in-process watcher never saw it).
    @ObservationIgnored var pendingAutomationWakeURL: URL?
    // Library facts (D1): the load chain is the SOLE writer (chrome-
    // mirror convention, pinned); views and view-models only read.
    var libraryTracks: [Track] = []
    var libraryMetrics: MetricsSnapshotValues?
    var lastLibraryScanDate: Date?
    var libraryLoadError: LibraryLoadError?
    var isLibraryLoading = false
    var libraryReadiness: MirrorReadiness = .incomplete(.freshObservationRequired)
    var catalogSnapshot: CatalogSnapshot?
    var catalogSnapshotSource: CatalogSnapshotSource?
    var catalogLoadIssue: String?
    var isLibraryReadyForUpdates: Bool {
        libraryReadiness.isReady
    }
    @ObservationIgnored let libraryLoadGate = RequestTokenGate()
    @ObservationIgnored let catalogLoadGate = RequestTokenGate()
    @ObservationIgnored let analyticsReportGate = RequestTokenGate()
    /// Replay-safe current-facts hook; the full-load hook may start non-idempotent work.
    @ObservationIgnored var onMirrorFactsApplied: (@MainActor ([Track]) -> Void)?
    @ObservationIgnored var onLibraryLoadApplied: (@MainActor ([Track]) -> Void)?
    /// Browse truth application stays host-owned (row-index pairing is
    /// view state); callers hand it one explicit processing snapshot.
    @ObservationIgnored var applyBrowseTruth: (@MainActor (BrowseProcessingFacts, UInt64?) async -> Void)?
    @ObservationIgnored let projectionStore = ProjectionStore()
    private(set) var configurationLoadIssue: String?
    @ObservationIgnored private let configurationLoader: () throws -> AppConfiguration
    @ObservationIgnored private let configurationSaver: (AppConfiguration) throws -> Void
    @ObservationIgnored private let modelContainerFactory: () throws -> ModelContainer?
    @ObservationIgnored let legacyPreferenceStore: UserDefaults
    @ObservationIgnored private var configurationSaveRecoveryState: AppState?

    // MARK: - Services (lazy, initialized in initialize())

    private(set) var scriptInstaller: ScriptInstaller?
    @ObservationIgnored private(set) var musicCatalog: any MusicCatalogReading
    private(set) var applescriptBridge: AppleScriptBridge?
    /// Verifier used to re-read attempted work during recovery clearance;
    /// production wiring points it at the AppleScript bridge.
    var recoveryVerifier: (any MusicAppVerifying)?
    /// Availability probe consulted before recovery observation so a blocked
    /// environment surfaces an actionable reason instead of a generic failure.
    private(set) var recoveryAvailability: RecoveryAvailability?
    private(set) var subscriptionService: SubscriptionService?
    private(set) var featureGate: FeatureGate?
    private(set) var networkReachabilityMonitor: NetworkReachabilityMonitor?
    private(set) var apiOrchestrator: APIOrchestrator?
    private(set) var pendingVerificationService: (any PendingVerificationService)?
    private(set) var cacheService: GRDBCacheService?
    private(set) var catalogStore: CatalogDataStore?
    private(set) var trackStore: (any TrackStateStore)?
    private(set) var changeLogStore: (any ChangeLogStore)?
    private(set) var metricsSnapshotStore: MetricsSnapshotStore?
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
    let lifecycleRelay = LifecycleRelay()
    @ObservationIgnored let discogsAccessStore = DiscogsAccessStore()
    private(set) var runRecordStore: (any RunRecordStore)?
    private(set) var fixPlanStore: (any FixPlanStore)?
    private(set) var librarySnapshotService: (any LibrarySnapshotService)?
    var mirrorEffectDrain: MirrorEffectDrain?
    @ObservationIgnored var mirrorProjectionOutput: AppMirrorProjectionOutput?
    var mirrorEffectDrainIssue: OperationalIssue?
    private(set) var analyticsService: AnalyticsRecorder?
    private let analyticsSessionID = UUID()
    private(set) var maintenanceCoordinator: MaintenanceCoordinator?
    var maintenancePreflightResult: MaintenancePreflightResult?
    private(set) var changePreviewPipeline: ChangePreviewPipeline?
    private(set) var incrementalRunTracker: IncrementalRunTracker?
    @ObservationIgnored private(set) var previousIncrementalScopeTracks: [Track] = []
    private(set) var discogsCredentialIssue: DiscogsCredentialIssue?
    private(set) var isDiscogsAccessAvailable: Bool?
    @ObservationIgnored var trackCountSource: (@Sendable () async -> Int?)?
    @ObservationIgnored var recoveryClearTasks: [UUID: Task<Void, Error>] = [:]
    @ObservationIgnored let recoveryMutationGate = RecoveryMutationGate()
    @ObservationIgnored private var isInitializing = false

    func setDiscogsIssue(_ issue: DiscogsCredentialIssue?) {
        discogsCredentialIssue = issue
        isDiscogsAccessAvailable = issue == nil
    }

    // MARK: - Init

    init(
        configurationLoader: @escaping () throws -> AppConfiguration = { try loadProcessConfiguration() },
        configurationSaver: @escaping (AppConfiguration) throws -> Void = { try $0.save() },
        modelContainerFactory: @escaping () throws -> ModelContainer? = makeProcessContainer,
        musicCatalog: any MusicCatalogReading = makeProcessMusicCatalog(),
        legacyPreferenceStore: UserDefaults = .standard
    ) {
        self.configurationLoader = configurationLoader
        self.configurationSaver = configurationSaver
        self.modelContainerFactory = modelContainerFactory
        self.musicCatalog = MeasuredMusicCatalog(base: musicCatalog)
        self.legacyPreferenceStore = legacyPreferenceStore

        do {
            config = try configurationLoader()
        } catch {
            let message = Self.loadFailureMessage(for: error)
            config = AppConfiguration()
            configurationLoadIssue = message
            appState = .error(message)
            log.error("Configuration load failed: \(message, privacy: .private)")
        }

        // Production creates the container eagerly so SwiftUI can attach it immediately.
        // Injected unit-test hosts intentionally leave it absent until a test provides one.
        do {
            modelContainer = try modelContainerFactory()
        } catch {
            log.error("Failed to create ModelContainer in init: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    private func beginInitialization() -> Bool {
        guard !isInitializing else { return false }
        if case .ready = appState {
            return false
        }
        isInitializing = true
        return true
    }

    /// Publishes the launch-time projections; false means a failed load
    /// blocks service initialization until an accepted command repairs it.
    private func bootstrapProjectionsForLaunch() async -> Bool {
        if let configurationLoadIssue {
            appState = .error(configurationLoadIssue)
            await publishSettingsProjection()
            await refreshChromeProjection()
            return false
        }

        if AppProcessMode.current.shouldUsePersistentStorage {
            migrateDefaultUpdateBehaviorIfNeeded()
        }
        // Bootstrap the settings projection so the store never serves the
        // `.empty` default state once the app is running. In production, a
        // migration persist failure is not fatal (the key is kept for a retry
        // next launch), but its message must survive into the projection —
        // appState is about to become .loading. Test hosts publish without
        // migrating user-owned preferences.
        await publishSettingsProjection(saveErrorMessage: configurationSaveErrorMessage)
        await refreshChromeProjection()
        return true
    }

    /// Initialize all services and determine app state. Re-entry safe:
    /// a window re-creation re-fires the launch task; initializing twice
    /// would rebuild live services mid-flight (onboarding-complete and
    /// error-retry paths still pass the guard).
    func initialize() async {
        guard beginInitialization() else { return }
        resetLifecycleProjectionState()
        defer { isInitializing = false }

        guard await bootstrapProjectionsForLaunch() else { return }
        appState = .loading

        guard AppProcessMode.current.shouldStartLiveServices else { return }

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
            recoveryVerifier = bridge
            recoveryAvailability = RecoveryAvailability(checks: .live(installer: installer))

            // Step 4: Start subscription service + feature gate
            let subscription = makeSubscriptionService()
            await subscription.start()
            subscriptionService = subscription

            #if DEBUG
            let gate = Self.makeFeatureGate(for: subscription, fixedTier: .pro)
            log.info("DEBUG: FeatureGate set to .pro (all features unlocked)")
            #else
            let gate = Self.makeFeatureGate(for: subscription)
            #endif
            featureGate = gate
            appliedTier = gate.currentTier
            let canUseAdvancedCache = gate.canAccess(.advancedCache)
            appliedCacheAccess = canUseAdvancedCache
            let cacheConfiguration = Self.effectiveCacheConfiguration(config, canUseAdvancedCache: canUseAdvancedCache)

            // Steps 5-8: Persistence, algorithms, API, and workflow services
            try await initializePersistence(cacheConfiguration: cacheConfiguration)
            try await initializeAlgorithmsAndAPI(cacheConfiguration: cacheConfiguration)
            try await initializeWorkflowServices(bridge: bridge, gate: gate)

            log.info("All services initialized successfully")
            appState = .ready
            await completeLaunch()
        } catch {
            log.error("Initialization failed: \(error.localizedDescription, privacy: .public)")
            appState = .error(error.localizedDescription)
        }
    }

    func retryInitialization() async {
        if configurationLoadIssue != nil {
            do {
                config = try configurationLoader()
                configurationLoadIssue = nil
            } catch {
                let message = Self.loadFailureMessage(for: error)
                configurationLoadIssue = message
                appState = .error(message)
                log.error("Configuration reload failed: \(message, privacy: .private)")
                return
            }
        }
        await initialize()
    }

    /// Called when onboarding completes script installation.
    func onboardingComplete() async {
        log.info("Onboarding complete — reinitializing")
        await initialize()
    }

    func replacePreviousIncrementalScopeTracks(_ tracks: [Track]) {
        previousIncrementalScopeTracks = tracks
    }

    /// Corrupted-persistence condition blocking future settings mutations;
    /// called from the command choke point (dispatch sites cannot show it).
    func reportSettingsRevisionCorruption(_ message: String) {
        appState = .error(message)
    }

    func reportRuntimeError(_ message: String) {
        appState = .error(message)
    }

    /// Persists WITHOUT runtime effects (the settings command path owns
    /// the apply); a successful save also repairs a failed initial load.
    @discardableResult
    func persistConfiguration() -> ConfigurationSaveResult {
        do {
            try configurationSaver(config)
            configurationLoadIssue = nil
            clearConfigurationSaveIssue()
            // The persisted config carries the current defaultUpdateBehavior,
            // so any pending legacy-key migration is superseded: a stale key
            // must not overwrite a newer explicit choice on the next launch.
            legacyPreferenceStore.removeObject(forKey: AppStorageKey.defaultUpdateBehavior)
            return .saved
        } catch {
            let message = "\(configurationSaveErrorPrefix) \(error.localizedDescription)"
            log
                .error(
                    "\(configurationSaveErrorPrefix, privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
            rememberConfigurationSaveRecoveryState()
            appState = .error(message)
            if let validationError = error as? ConfigurationValidationError {
                return .invalid(validationError)
            }
            return .unavailable
        }
    }

    private static func loadFailureMessage(for error: any Error) -> String {
        "Failed to load configuration at \(AppConfiguration.configFileURL.path): \(error.localizedDescription) " +
            "Review or repair that file, save it, then choose Try Again."
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
    func initializePersistence(cacheConfiguration: AppConfiguration) async throws {
        let container: ModelContainer
        if let existing = modelContainer {
            container = existing
        } else {
            guard let createdContainer = try modelContainerFactory() else {
                throw DependencySetupError.missingModelContainer
            }
            container = createdContainer
            modelContainer = container
        }

        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        trackStore = store
        catalogStore = CatalogDataStore(modelContainer: container)

        let logStore = ChangeLogDataStore(modelContainer: container)
        changeLogStore = logStore
        metricsSnapshotStore = MetricsSnapshotStore(modelContainer: container)

        runRecordStore = RunRecordDataStore(modelContainer: container)
        fixPlanStore = FixPlanDataStore(modelContainer: container)

        let cache = try makeProcessCache(
            configuration: cacheConfiguration,
            apiResultTTL: Self.apiResultCacheTTL(configuration: cacheConfiguration)
        )
        try await cache.initialize()
        cacheService = cache
        librarySnapshotService = Self.makeSnapshotService(cache: cache, configuration: cacheConfiguration)
        await installMirrorEffectDrain(store: store, cache: cache)
        let analyticsRecorder = AnalyticsRecorder(
            store: cache,
            configuration: cacheConfiguration.analytics,
            sessionID: analyticsSessionID
        )
        await analyticsRecorder.initialize()
        analyticsService = analyticsRecorder
        if let applescriptBridge {
            await applescriptBridge.updateAnalytics(analyticsRecorder)
        }
        if let measuredCatalog = musicCatalog as? MeasuredMusicCatalog {
            await measuredCatalog.updateAnalytics(analyticsRecorder)
        }
    }

    /// Steps 6-7: Create core algorithm instances and API orchestrator.
    private func initializeAlgorithmsAndAPI(cacheConfiguration: AppConfiguration) async throws {
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
            configuration: cacheConfiguration,
            cache: cacheService,
            reachability: reachability,
            analytics: analyticsService,
            factoryOverrides: APIClientFactoryOverrides(discogsCredentialIssueHandler: { [weak self] issue in
                self?.setDiscogsIssue(issue)
            })
        )
    }

    /// The ready tail, extracted so launch-time obligations are
    /// pinnable: chrome republish (probed facts exist only now), the
    /// lifecycle observer, and the persisted automation strategy.
    func completeLaunch() async {
        // Republish chrome now that every probed fact exists — the
        // bootstrap publish ran before services were built, and a fresh
        // session emits no lifecycle event to re-derive it.
        await refreshChromeProjection()
        startLifecycleProjectionObserver()
        _ = await ensureRecoveryHold()
        if agentRegistrar == nil {
            agentRegistrar = SMAppServiceRegistrar()
        }
        await applyAutomationStrategy()
        await drainPendingAutomationWake()
    }

    /// Creates the tracker and primes the chrome due-fact cache (D6).
    private func installIncrementalRunTracker() async {
        incrementalRunTracker = Self.makeIncrementalRunTracker(configuration: config)
        await refreshIncrementalRunTimestamp()
    }

    /// Step 8: Wire workflow services that depend on persistence, algorithms, and the script bridge.
    private func initializeWorkflowServices(bridge: AppleScriptBridge, gate: FeatureGate) async throws {
        let checkpoint = await prepareWorkflowCheckpoint()

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
            musicApp: bridge,
            idMapper: mapper,
            stores: Self.makeUndoStores(changeLogStore: logStore, trackStore: store, cache: cache),
            librarySnapshotService: librarySnapshotService,
            effectDrain: mirrorEffectDrain,
            cleaning: config.cleaning
        )
        await undo.initialize()
        undoCoordinator = undo

        updateCoordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: orchestrator,
                writer: bridge,
                stores: .init(trackStore: store, cache: cache),
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: librarySnapshotService,
                pendingVerificationService: pendingVerificationService,
                analytics: analyticsService,
                effectDrain: mirrorEffectDrain
            ),
            genreDeterminator: genreDeterm,
            yearDeterminator: yearDeterm,
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: config)
        )

        let processor = makeBatchProcessor(checkpoint: checkpoint, gate: gate)
        batchProcessor = processor

        let syncService = try makeLibrarySyncService(
            bridge: bridge,
            store: store,
            effectDrain: mirrorEffectDrain
        )
        librarySyncService = syncService
        let createdRunOrchestrator = makeRunOrchestrator(
            syncService: syncService,
            runRecordStore: recordStore,
            processor: processor
        )
        runOrchestrator = createdRunOrchestrator
        await lifecycleRelay.attach(to: createdRunOrchestrator)

        maintenanceCoordinator = MaintenanceCoordinator(
            databaseVerificationService: syncService,
            pendingVerificationService: pendingVerificationService
        )

        changePreviewPipeline = ChangePreviewPipeline()
    }

    private func prepareWorkflowCheckpoint() async -> CheckpointManager {
        let checkpoint = CheckpointManager()
        checkpointManager = checkpoint
        await installIncrementalRunTracker()
        return checkpoint
    }

    func refreshFixPlanProjection() async -> FixPlanProjection {
        let inputGeneration = await projectionStore.nextFixPlanInputGeneration()
        let projection: FixPlanProjection
        do {
            projection = try await latestFixPlanProjection()
        } catch {
            projection = .unavailable(message: error.localizedDescription)
        }
        return await projectionStore.replaceFixPlanProjection(projection, inputGeneration: inputGeneration)
    }

    func refreshFixPlanFromStore() async throws -> FixPlanProjection {
        let inputGeneration = await projectionStore.nextFixPlanInputGeneration()
        let projection = try await latestFixPlanProjection()
        return await projectionStore.replaceFixPlanProjection(projection, inputGeneration: inputGeneration)
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
        let currentConfiguration = captureFixPlanConfig(
            at: now,
            hasDiscogsAccess: isDiscogsAccessAvailable ?? plan.configuration.hasDiscogsAccess,
            // The album target is the plan's identity, not a live setting:
            // staleness must compare the rest of the configuration against
            // the same target, or every targeted plan is instantly stale.
            albumTarget: plan.configuration.albumTarget
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

    func runHistoryLimit() -> Int {
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
        trackStore: (any TrackStateStore)? = nil,
        catalogStore: CatalogDataStore? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil,
        metricsSnapshotStore: MetricsSnapshotStore? = nil,
        runRecordStore: (any RunRecordStore)? = nil,
        fixPlanStore: (any FixPlanStore)? = nil,
        cache: GRDBCacheService? = nil
    ) {
        self.trackStore = trackStore
        self.catalogStore = catalogStore
        self.librarySnapshotService = librarySnapshotService
        self.metricsSnapshotStore = metricsSnapshotStore
        self.runRecordStore = runRecordStore
        self.fixPlanStore = fixPlanStore
        cacheService = cache
        if let trackStore, let cache {
            let projectionOutput = AppMirrorProjectionOutput(dependencies: self)
            mirrorProjectionOutput = projectionOutput
            mirrorEffectDrain = MirrorEffectDrain(
                store: trackStore,
                cache: cache,
                snapshot: librarySnapshotService,
                projections: projectionOutput,
                reporter: AppMirrorEffectReporter(dependencies: self)
            )
        }
    }

    func installTestChangeLogStore(_ store: any ChangeLogStore) {
        changeLogStore = store
    }

    func installTestOrchestrator(_ orchestrator: RunOrchestrator) async {
        runOrchestrator = orchestrator
        await lifecycleRelay.attach(to: orchestrator)
    }

    func installTestFeatureGate(_ gate: FeatureGate) {
        featureGate = gate
        appliedTier = gate.currentTier
        appliedCacheAccess = gate.canAccess(.advancedCache)
    }

    func installTestIncrementalRunTracker(_ tracker: IncrementalRunTracker) {
        incrementalRunTracker = tracker
    }
    func installTestAnalyticsRecorder(_ recorder: AnalyticsRecorder) {
        analyticsService = recorder
    }
    func installTestAgentRegistrar(_ registrar: any AgentRegistrar) {
        agentRegistrar = registrar
    }
    func installTestAvailability(_ availability: RecoveryAvailability) {
        recoveryAvailability = availability
    }
}
#endif

extension AppDependencies {
    func applyRuntimeConfigurationHead() throws -> RuntimeApplyHandoff {
        let canUseAdvancedCache = featureGate?.canAccess(.advancedCache) == true
        let cacheConfiguration = Self.effectiveCacheConfiguration(config, canUseAdvancedCache: canUseAdvancedCache)
        let configuredYearDeterminator = Self.makeYearDeterminator(configuration: config)
        let configuredTracker = Self.makeIncrementalRunTracker(configuration: config)
        let syncRuntime = try LibrarySyncRuntimeConfiguration(configuration: config)
        let pendingVerificationStore = modelContainer.map {
            PendingVerificationStore(modelContainer: $0, configuration: config)
        }
        let configuredAPIOrchestrator = Self.makeAPIOrchestrator(
            configuration: cacheConfiguration,
            cache: cacheService,
            reachability: networkReachabilityMonitor,
            analytics: analyticsService,
            factoryOverrides: APIClientFactoryOverrides(discogsCredentialIssueHandler: { [weak self] issue in
                self?.setDiscogsIssue(issue)
            })
        )
        let maintenance = librarySyncService.map { syncService in
            MaintenanceCoordinator(
                databaseVerificationService: syncService,
                pendingVerificationService: pendingVerificationStore
            )
        }
        let snapshotService: (any LibrarySnapshotService)? = if let cacheService {
            Self.makeSnapshotService(cache: cacheService, configuration: cacheConfiguration)
        } else {
            nil
        }

        let handoff = RuntimeApplyHandoff(
            pendingVerificationStore: pendingVerificationStore,
            snapshotService: snapshotService,
            yearDeterminator: configuredYearDeterminator,
            apiOrchestrator: configuredAPIOrchestrator,
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: config),
            appleScriptConfiguration: config.applescript,
            librarySyncRuntimeConfiguration: syncRuntime,
            batchProcessingConfiguration: BatchProcessingConfiguration(configuration: config),
            libraryPath: config.paths.musicLibraryPath,
            analytics: cacheConfiguration.analytics,
            cleaning: config.cleaning,
            cacheConfiguration: cacheConfiguration
        )

        incrementalRunTracker = configuredTracker
        yearDeterminator = configuredYearDeterminator
        pendingVerificationService = pendingVerificationStore
        apiOrchestrator = configuredAPIOrchestrator
        if let maintenance {
            maintenanceCoordinator = maintenance
        }
        if let snapshotService {
            librarySnapshotService = snapshotService
        }
        return handoff
    }

    private static func makeIncrementalRunTracker(configuration: AppConfiguration) -> IncrementalRunTracker {
        IncrementalRunTracker(
            logsBaseDirectory: configuration.paths.effectiveLogsBaseDirectory,
            lastIncrementalRunFile: configuration.logging.lastIncrementalRunFile
        )
    }
}
