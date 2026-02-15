// AppDependencies.swift — Composition root and app state management
// Ported from: src/services/dependency_container.py (563 LOC → ~80 LOC)
//
// Python's DI container manually registered + resolved ~20 services with lifecycle management.
// Swift replaces this with:
// - Constructor injection (compile-time safety)
// - @EnvironmentObject for SwiftUI propagation
// - Lazy initialization via async initialize()
//
// The massive LOC reduction comes from:
// - No registration/resolution boilerplate
// - No metaclass tricks for singletons
// - SwiftUI handles view lifecycle automatically

import Core
import OSLog
import Services
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
/// Published as `@EnvironmentObject` to make services available throughout the view hierarchy.
///
/// ## Initialization Order
/// 1. Load configuration
/// 2. Check script installation status
/// 3. If scripts installed → ready; else → onboarding
@MainActor
final class AppDependencies: ObservableObject {
    // MARK: - Published State

    @Published private(set) var appState: AppState = .loading
    @Published private(set) var config: AppConfiguration

    // MARK: - Services (lazy, initialized in initialize())

    private(set) var scriptInstaller: ScriptInstaller?
    private(set) var musicReader: MusicLibraryReader?
    private(set) var applescriptBridge: AppleScriptBridge?
    private(set) var subscriptionService: SubscriptionService?
    private(set) var featureGate: FeatureGate?

    // MARK: - Init

    init() {
        // Load config synchronously (it's just JSON from disk)
        self.config = (try? AppConfiguration.load()) ?? AppConfiguration()
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
            self.scriptInstaller = installer

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
            self.applescriptBridge = bridge

            let reader = MusicLibraryReader()
            self.musicReader = reader

            // Step 4: Start subscription service + feature gate
            let subscription = SubscriptionService()
            await subscription.start()
            self.subscriptionService = subscription
            self.featureGate = FeatureGate(
                tierProvider: { [weak subscription] in subscription?.currentTier ?? .free },
                freeTracksUsedProvider: { [weak subscription] in subscription?.freeTracksUsed ?? 0 }
            )

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
}
