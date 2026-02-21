// AppDependencies.swift — Composition root and app state management
// Ported from: src/services/dependency_container.py (563 LOC → ~80 LOC)
//
// Python's DI container manually registered + resolved ~20 services with lifecycle management.
// Swift replaces this with:
// - Constructor injection (compile-time safety)
// - @Environment for SwiftUI propagation (@Observable)
// - Lazy initialization via async initialize()
//
// The massive LOC reduction comes from:
// - No registration/resolution boilerplate
// - No metaclass tricks for singletons
// - SwiftUI handles view lifecycle automatically

import Core
import OSLog
import Services
import SwiftData
import SwiftUI

private let log = AppLogger.make(category: "dependencies")

// MARK: - App State

/// Represents the current state of the application.
enum AppState: Sendable {
    case loading
    case needsOnboarding
    case ready
    case error(String)
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
    var config: AppConfiguration

    // MARK: - Services (lazy, initialized in initialize())

    private(set) var scriptInstaller: ScriptInstaller?
    private(set) var musicReader: MusicLibraryReader?
    private(set) var applescriptBridge: AppleScriptBridge?
    private(set) var subscriptionService: SubscriptionService?
    private(set) var featureGate: FeatureGate?
    private(set) var apiOrchestrator: APIOrchestrator?
    private(set) var cacheService: GRDBCacheService?
    private(set) var trackStore: SwiftDataTrackStore?
    private(set) var changeLogStore: SwiftDataChangeLogStore?
    private(set) var modelContainer: ModelContainer?
    private(set) var genreDeterminator: GenreDeterminator?
    private(set) var yearDeterminator: YearDeterminator?
    private(set) var updateCoordinator: UpdateCoordinator?
    private(set) var batchProcessor: BatchProcessor?
    private(set) var undoCoordinator: UndoCoordinator?
    private(set) var checkpointManager: CheckpointManager?
    private(set) var librarySyncService: LibrarySyncService?
    private(set) var changePreviewPipeline: ChangePreviewPipeline?

    // MARK: - Init

    init() {
        // Load config synchronously (it's just JSON from disk)
        config = (try? AppConfiguration.load()) ?? AppConfiguration()

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
        appState = .loading

        do {
            // Step 1: Create script installer
            let installer = try ScriptInstaller()
            scriptInstaller = installer

            // Step 2: Check if scripts are installed
            let scriptsReady = await installer.areScriptsInstalled()

            if !scriptsReady {
                log.info("Scripts not installed — showing onboarding")
                appState = .needsOnboarding
                return
            }

            // Step 3: Initialize services
            let bridge = AppleScriptBridge(installer: installer, config: config.applescript)
            try await bridge.initialize()
            applescriptBridge = bridge

            let reader = MusicLibraryReader(
                testArtists: config.development.testArtists
            )
            musicReader = reader

            // Step 4: Start subscription service + feature gate
            let subscription = SubscriptionService()
            await subscription.start()
            subscriptionService = subscription
            let gate = FeatureGate(
                tierProvider: { [weak subscription] in subscription?.currentTier ?? .free },
                freeTracksUsedProvider: { [weak subscription] in subscription?.freeTracksUsed ?? 0 }
            )
            featureGate = gate

            // Steps 5-8: Persistence, algorithms, API, and workflow services
            try await initializePersistence()
            initializeAlgorithmsAndAPI()
            initializeWorkflowServices(bridge: bridge, gate: gate)

            log.info("All services initialized successfully")
            appState = .ready
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

    /// Refresh library data (triggered by Cmd+R).
    func refreshLibrary() async {
        guard let reader = musicReader else { return }
        do {
            try await reader.requestAuthorization()
            log.info("Library refresh triggered")
        } catch {
            log.error("Library refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Save current state (called on scene phase change to inactive).
    func saveState() async {
        do {
            try config.save()
            log.debug("App state saved")
        } catch {
            log.error("Failed to save state: \(error.localizedDescription, privacy: .public)")
        }
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

        let store = SwiftDataTrackStore(modelContainer: container)
        try await store.initialize()
        trackStore = store

        let logStore = SwiftDataChangeLogStore(modelContainer: container)
        changeLogStore = logStore

        let cache = try GRDBCacheService.createDefault()
        try await cache.initialize()
        cacheService = cache
    }

    /// Steps 6-7: Create core algorithm instances and API orchestrator.
    private func initializeAlgorithmsAndAPI() {
        let genreDeterm = GenreDeterminator()
        genreDeterminator = genreDeterm

        let yearDeterm = YearDeterminator()
        yearDeterminator = yearDeterm

        // DiscogsClient gracefully handles missing Keychain token (nil token = unauthenticated).
        let discogsClient = (try? DiscogsClient.fromKeychain()) ?? DiscogsClient()
        let orchestrator = APIOrchestrator(
            musicBrainz: MusicBrainzClient(),
            discogs: discogsClient,
            appleMusic: AppleMusicSearchClient()
        )
        apiOrchestrator = orchestrator
    }

    /// Step 8: Wire workflow services that depend on persistence, algorithms, and the script bridge.
    private func initializeWorkflowServices(bridge: AppleScriptBridge, gate: FeatureGate) {
        let checkpoint = CheckpointManager()
        checkpointManager = checkpoint

        guard let logStore = changeLogStore,
              let store = trackStore,
              let cache = cacheService,
              let orchestrator = apiOrchestrator,
              let genreDeterm = genreDeterminator,
              yearDeterminator != nil
        else {
            log.error("Cannot initialize workflow services — prerequisite services are nil")
            return
        }

        let undo = UndoCoordinator(
            scriptBridge: bridge,
            changeLogStore: logStore
        )
        undoCoordinator = undo

        updateCoordinator = UpdateCoordinator(
            apiOrchestrator: orchestrator,
            scriptBridge: bridge,
            trackStore: store,
            cache: cache,
            undoCoordinator: undo,
            genreDeterminator: genreDeterm
        )

        batchProcessor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate
        )

        librarySyncService = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate
        )

        changePreviewPipeline = ChangePreviewPipeline()
    }
}
