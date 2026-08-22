import Foundation
import Testing
@testable import Core

@Suite("Analytics configuration")
struct AnalyticsConfigurationTests {
    @Test("Recent detail uses a bounded default")
    func recentLimitDefault() {
        #expect(AnalyticsConfig().recentEventLimit == 100)
    }

    @Test("Recent detail limit persists and legacy files receive the default")
    func recentLimitPersistence() throws {
        let explicit = try JSONDecoder().decode(
            AnalyticsConfig.self,
            from: Data(#"{"recentEventLimit":45}"#.utf8)
        )
        let legacy = try JSONDecoder().decode(
            AnalyticsConfig.self,
            from: Data(#"{"enabled":true,"maxEvents":50}"#.utf8)
        )
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(explicit)) as? [String: Any]
        )

        #expect(explicit.recentEventLimit == 45)
        #expect(legacy.recentEventLimit == 100)
        #expect(encoded["recentEventLimit"] as? Int == 45)
    }

    @Test("Recent detail limit must be positive")
    func recentLimitValidation() {
        var configuration = AppConfiguration()
        configuration.analytics.recentEventLimit = 0

        #expect(throws: ConfigurationValidationError.self) {
            try configuration.validate()
        }
    }
}
