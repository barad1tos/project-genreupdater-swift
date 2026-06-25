// AppDependencies.swift — Composition root and app state management.

import Core
import Foundation
import OSLog
import Services
import SwiftData
import SwiftUI

private let log = AppLogger.make(category: "dependencies")
private let configurationSaveErrorPrefix = "Failed to save configuration:"

private enum AppDependencyInitializationError: LocalizedError {
    case missingModelContainer

    var errorDescription: String? {
        switch self {
        case .missingModelContainer:
            "SwiftData model container is unavailable"
        }
    }
}

enum APIAuthReferenceResolver {
    static func resolve(
        _ reference: String,
        fallbackUserDefaultsKey: String? = nil
    ) -> String {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReference.isEmpty else { return "" }

        if let placeholderName = placeholderName(from: trimmedReference) {
            return value(forKey: placeholderName)
                ?? fallbackUserDefaultsKey.flatMap(value(forKey:))
                ?? ""
        }

        return value(forKey: trimmedReference) ?? trimmedReference
    }

    private static func placeholderName(from reference: String) -> String? {
        guard reference.hasPrefix("${"), reference.hasSuffix("}") else { return nil }
        return String(reference.dropFirst(2).dropLast())
    }

    private static func value(forKey key: String) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        return ProcessInfo.processInfo.environment[trimmedKey].flatMap(nonEmpty)
            ?? UserDefaults.standard.string(forKey: trimmedKey).flatMap(nonEmpty)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

// MARK: - App State

/// Represents the current state of the application.
enum AppState {
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
    var isAutoSyncRunning = false
    private(set) var configurationLoadIssue: String?
    @ObservationIgnored private let configurationSaver: (AppConfiguration) throws -> Void
    @ObservationIgnored private var configurationSaveRecoveryState: AppState?

    // MARK: - Services (lazy, initialized in initialize())

    private(set) var scriptInstaller: ScriptInstaller?
    private(set) var musicReader: MusicLibraryReader?
    private(set) var applescriptBridge: AppleScriptBridge?
    private(set) var subscriptionService: SubscriptionService?
    private(set) var featureGate: FeatureGate?
    private(set) var networkReachabilityMonitor: NetworkReachabilityMonitor?
    private(set) var apiOrchestrator: APIOrchestrator?
    private(set) var pendingVerificationService: (any PendingVerificationService)?
    private(set) var cacheService: GRDBCacheService?
    private(set) var trackStore: SwiftDataTrackStore?
    private(set) var changeLogStore: SwiftDataChangeLogStore?
    private(set) var modelContainer: ModelContainer?
    private(set) var genreDeterminator: GenreDeterminator?
    private(set) var yearDeterminator: YearDeterminator?
    private(set) var updateCoordinator: UpdateCoordinator?
    private(set) var batchProcessor: BatchProcessor?
    private(set) var undoCoordinator: UndoCoordinator?
    private(set) var trackIDMapper: TrackIDMapper?
    private(set) var checkpointManager: CheckpointManager?
    private(set) var librarySyncService: LibrarySyncService?
    private(set) var librarySnapshotService: (any LibrarySnapshotService)?
    private(set) var analyticsService: CachedAnalyticsService?
    private(set) var maintenanceCoordinator: MaintenanceCoordinator?
    var maintenancePreflightResult: MaintenancePreflightResult?
    private(set) var changePreviewPipeline: ChangePreviewPipeline?
    private(set) var incrementalRunTracker: IncrementalRunTracker?
    @ObservationIgnored private(set) var previousIncrementalScopeTracks: [Track] = []
    private(set) var discogsCredentialIssue: DiscogsCredentialIssue?

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
            return
        }

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

            guard await installer.areScriptsInstalled() else {
                log.info("Scripts not installed after refresh attempt — showing onboarding")
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
            await initializeWorkflowServices(bridge: bridge, gate: gate)

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

    func replacePreviousIncrementalScopeTracks(_ tracks: [Track]) {
        previousIncrementalScopeTracks = tracks
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
            try configurationSaver(config)
            log.debug("App state saved")
        } catch {
            log.error("Failed to save state: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func saveConfigurationAndApplyRuntime() -> Bool {
        do {
            try configurationSaver(config)
            applyRuntimeConfiguration()
            clearConfigurationSaveIssue()
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

    private func isConfigurationSaveIssue(_ state: AppState) -> Bool {
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

        let store = SwiftDataTrackStore(modelContainer: container)
        try await store.initialize()
        trackStore = store

        let logStore = SwiftDataChangeLogStore(modelContainer: container)
        changeLogStore = logStore

        let cache = try GRDBCacheService.createDefault(
            defaultGenericTTL: Self.defaultGenericCacheTTL(configuration: config),
            apiResultTTL: Self.apiResultCacheTTL(configuration: config),
            maxGenericEntries: config.runtime.maxGenericEntries,
            cleanupInterval: TimeInterval(config.caching.cleanupIntervalSeconds)
        )
        try await cache.initialize()
        cacheService = cache
        librarySnapshotService = Self.makeLibrarySnapshotService(cache: cache, configuration: config)
        analyticsService = CachedAnalyticsService(
            cache: cache,
            configuration: config.analytics
        )
    }

    private static func defaultGenericCacheTTL(configuration: AppConfiguration) -> TimeInterval {
        let candidates = [
            configuration.caching.defaultTTLSeconds,
            configuration.runtime.cacheTTLSeconds,
        ]

        for seconds in candidates where seconds > 0 {
            return TimeInterval(seconds)
        }

        return 5 * 60
    }

    static func apiResultCacheTTL(configuration: AppConfiguration) -> TimeInterval {
        guard configuration.processing.cacheTTLDays > 0 else {
            return GRDBCacheService.defaultAPIResultTTL
        }

        return TimeInterval(configuration.processing.cacheTTLDays) * 24 * 60 * 60
    }

    private static func makeYearDeterminator(configuration: AppConfiguration) -> YearDeterminator {
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
            throw AppDependencyInitializationError.missingModelContainer
        }

        let pendingVerification = SwiftDataPendingVerificationService(modelContainer: container, configuration: config)
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
                self?.discogsCredentialIssue = issue
            })
        )
    }

    /// Step 8: Wire workflow services that depend on persistence, algorithms, and the script bridge.
    private func initializeWorkflowServices(bridge: AppleScriptBridge, gate: FeatureGate) async {
        let checkpoint = CheckpointManager()
        checkpointManager = checkpoint
        incrementalRunTracker = Self.makeIncrementalRunTracker(configuration: config)

        guard let logStore = changeLogStore,
              let store = trackStore,
              let cache = cacheService,
              let orchestrator = apiOrchestrator,
              let genreDeterm = genreDeterminator,
              let yearDeterm = yearDeterminator
        else {
            log.error("Cannot initialize workflow services — prerequisite services are nil")
            return
        }

        let mapper = TrackIDMapper()
        trackIDMapper = mapper

        let undo = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: mapper,
            changeLogStore: logStore,
            cache: cache,
            librarySnapshotService: librarySnapshotService
        )
        await undo.initialize()
        undoCoordinator = undo

        updateCoordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                trackStore: store,
                cache: cache,
                undoCoordinator: undo,
                idMapper: mapper,
                librarySnapshotService: librarySnapshotService,
                pendingVerificationService: pendingVerificationService
            ),
            genreDeterminator: genreDeterm,
            yearDeterminator: yearDeterm,
            runtimeConfiguration: UpdateRuntimeConfiguration(configuration: config)
        )

        batchProcessor = BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate,
            processingConfiguration: BatchProcessingConfiguration(configuration: config)
        )

        let syncService = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            cache: cache,
            pendingVerificationService: pendingVerificationService,
            librarySnapshotService: librarySnapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(configuration: config)
        )
        librarySyncService = syncService

        maintenanceCoordinator = MaintenanceCoordinator(
            databaseVerificationService: syncService,
            pendingVerificationService: pendingVerificationService
        )

        changePreviewPipeline = ChangePreviewPipeline()
    }
}

extension AppDependencies {
    func applyRuntimeConfiguration() {
        let configuredYearDeterminator = Self.makeYearDeterminator(configuration: config)
        incrementalRunTracker = Self.makeIncrementalRunTracker(configuration: config)
        let configuredPendingVerificationService = modelContainer.map {
            SwiftDataPendingVerificationService(modelContainer: $0, configuration: config)
        }
        let configuredAPIOrchestrator = Self.makeAPIOrchestrator(
            configuration: config,
            cache: cacheService,
            pendingVerificationService: configuredPendingVerificationService,
            reachability: networkReachabilityMonitor,
            factoryOverrides: APIClientFactoryOverrides(discogsCredentialIssueHandler: { [weak self] issue in
                self?.discogsCredentialIssue = issue
            })
        )
        yearDeterminator = configuredYearDeterminator
        pendingVerificationService = configuredPendingVerificationService
        apiOrchestrator = configuredAPIOrchestrator
        if let librarySyncService {
            maintenanceCoordinator = MaintenanceCoordinator(
                databaseVerificationService: librarySyncService,
                pendingVerificationService: configuredPendingVerificationService
            )
        }
        let configuredLibrarySnapshotService: (any LibrarySnapshotService)?
        if let cacheService {
            let snapshotService = Self.makeLibrarySnapshotService(cache: cacheService, configuration: config)
            librarySnapshotService = snapshotService
            configuredLibrarySnapshotService = snapshotService
            analyticsService = CachedAnalyticsService(
                cache: cacheService,
                configuration: config.analytics
            )
        } else {
            configuredLibrarySnapshotService = nil
        }

        let runtimeConfiguration = UpdateRuntimeConfiguration(configuration: config)
        let appleScriptConfiguration = config.applescript
        let librarySyncRuntimeConfiguration = LibrarySyncRuntimeConfiguration(configuration: config)
        let batchProcessingConfiguration = BatchProcessingConfiguration(configuration: config)
        Task {
            try? await configuredPendingVerificationService?.initialize()
            await applescriptBridge?.updateConfiguration(appleScriptConfiguration)
            await musicReader?.updateTestArtists(config.development.testArtists)
            await librarySyncService?.updateRuntimeConfiguration(
                librarySyncRuntimeConfiguration,
                librarySnapshotService: configuredLibrarySnapshotService,
                pendingVerificationService: configuredPendingVerificationService
            )
            await batchProcessor?.updateProcessingConfiguration(batchProcessingConfiguration)
            await analyticsService?.updateConfiguration(config.analytics)
            await updateCoordinator?.updateRuntimeConfiguration(
                runtimeConfiguration,
                yearDeterminator: configuredYearDeterminator,
                apiOrchestrator: configuredAPIOrchestrator,
                librarySnapshotService: configuredLibrarySnapshotService
            )
            await undoCoordinator?.updateRuntimeDependencies(
                librarySnapshotService: configuredLibrarySnapshotService
            )
        }
    }

    private static func makeLibrarySnapshotService(
        cache: any CacheService,
        configuration: AppConfiguration
    ) -> CachedLibrarySnapshotService {
        CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration.caching.librarySnapshot,
            libraryModificationDateProvider: makeLibraryModificationDateProvider(
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

    private static func makeLibraryModificationDateProvider(path: String) -> @Sendable () -> Date? {
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
    func configureLibraryPersistenceForTesting(
        trackStore: SwiftDataTrackStore? = nil,
        librarySnapshotService: (any LibrarySnapshotService)? = nil
    ) {
        self.trackStore = trackStore
        self.librarySnapshotService = librarySnapshotService
    }
}
#endif
