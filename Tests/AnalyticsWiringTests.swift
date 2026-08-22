import Core
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Provider analytics composition")
@MainActor
struct AnalyticsWiringTests {
    @Test("Provider factories receive the shared analytics service")
    func providerFactories() {
        let analytics = FactoryAnalyticsProbe()
        let fallbackService = DashboardStateAPIService()
        var musicBrainzAnalytics: FactoryAnalyticsProbe?
        var catalogAnalytics: FactoryAnalyticsProbe?
        let factoryOverrides = APIClientFactoryOverrides(
            musicBrainzFactory: { _, _, _, _, transport in
                musicBrainzAnalytics = transport.analytics as? FactoryAnalyticsProbe
                return fallbackService
            },
            catalogFactory: { _, _, transport in
                catalogAnalytics = transport.analytics as? FactoryAnalyticsProbe
                return fallbackService
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: AppConfiguration(),
            cache: nil,
            reachability: nil,
            analytics: analytics,
            factoryOverrides: factoryOverrides
        )

        #expect(musicBrainzAnalytics === analytics)
        #expect(catalogAnalytics === analytics)
    }
}

private actor FactoryAnalyticsProbe: AnalyticsService {
    func record(_: AnalyticsOperation, duration _: Duration, outcome _: AnalyticsOutcome) {}
}
