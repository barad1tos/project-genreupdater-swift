import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("App process mode")
struct AppProcessModeTests {
    @Test("Injected unit-test hosts use isolated persistence without live startup")
    func unitTestHostPolicy() {
        let mode = AppProcessMode(environment: [
            "XCTestConfigurationFilePath": "injected",
        ])

        #expect(mode == .unitTestHost)
        #expect(!mode.shouldUsePersistentStorage)
        #expect(!mode.shouldStartLiveServices)
    }

    @Test("Ordinary app processes retain persistent storage and live startup")
    func applicationPolicy() {
        let mode = AppProcessMode(environment: [:])

        #expect(mode == .application)
        #expect(mode.shouldUsePersistentStorage)
        #expect(mode.shouldStartLiveServices)
    }

    @MainActor
    @Test("Default unit-test dependencies never connect to the live MusicKit catalog")
    func defaultCatalogIsInactive() async {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })

        #expect(await !dependencies.musicCatalog.isAuthorized)
        do {
            let trackCount = try await dependencies.musicCatalog.trackCount()
            Issue.record("Unit-test catalog reached the live library and returned \(trackCount) tracks")
        } catch let error as MusicLibraryError {
            guard case .musicAppNotAvailable = error else {
                Issue.record("Expected an inactive unit-test catalog, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MusicLibraryError.musicAppNotAvailable, got \(error)")
        }
    }

    @MainActor
    @Test("Direct unit-test initialization never starts live services")
    func directInitializationIsInert() async {
        let dependencies = AppDependencies(configurationLoader: { AppConfiguration() })

        await dependencies.initialize()

        guard case .loading = dependencies.appState else {
            Issue.record("Unit-test initialization changed app state to \(dependencies.appState)")
            return
        }
        #expect(dependencies.scriptInstaller == nil)
        #expect(dependencies.applescriptBridge == nil)
        #expect(dependencies.subscriptionService == nil)
    }
}
