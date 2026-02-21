import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - BatchProcessorError Tests

@Suite("BatchProcessorError — error descriptions")
struct BatchProcessorErrorTests {
    @Test("featureNotAvailable includes feature name and tier")
    func featureNotAvailable() {
        let error = BatchProcessorError.featureNotAvailable(
            feature: .batchProcessing,
            currentTier: .free
        )
        let description = error.errorDescription ?? ""
        #expect(description.contains("batchProcessing"))
        #expect(description.contains("free"))
    }

    @Test("alreadyRunning has a description")
    func alreadyRunning() {
        let error = BatchProcessorError.alreadyRunning
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("notRunning has a description")
    func notRunning() {
        let error = BatchProcessorError.notRunning
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("cancelled includes processed and total counts")
    func cancelled() {
        let error = BatchProcessorError.cancelled(processedCount: 25, totalCount: 100)
        let description = error.errorDescription ?? ""
        #expect(description.contains("25"))
        #expect(description.contains("100"))
    }
}

// MARK: - FeatureGateError Tests

@Suite("FeatureGateError — error construction")
struct FeatureGateErrorTests {
    @Test("featureRequiresTier contains correct values")
    func featureRequiresTier() {
        let error = FeatureGateError.featureRequiresTier(
            feature: .autoSync,
            required: .pro,
            current: .free
        )
        // Just verify construction succeeds
        if case let .featureRequiresTier(feature, required, current) = error {
            #expect(feature == .autoSync)
            #expect(required == .pro)
            #expect(current == .free)
        }
    }

    @Test("freeTrackLimitReached contains limit and used")
    func freeTrackLimitReached() {
        let error = FeatureGateError.freeTrackLimitReached(limit: 500, used: 499)
        if case let .freeTrackLimitReached(limit, used) = error {
            #expect(limit == 500)
            #expect(used == 499)
        }
    }
}
