import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Subscription runtime transitions")
@MainActor
struct SubscriptionRuntimeTests {
    @Test("Pro access arms configured automation and downgrade disarms it")
    func automationFollowsProAccess() async {
        let dependencies = AppDependencies()
        dependencies.config.runtime.automationStrategy = .scheduled
        dependencies.lastScheduledTickAt = Date()
        let subscription = dependencies.makeSubscriptionService()

        subscription.applyEntitlementState(tier: .weekPass, weekPassExpiry: nil, proExpiry: nil)
        dependencies.installTestFeatureGate(AppDependencies.makeFeatureGate(for: subscription))

        subscription.applyEntitlementState(tier: .pro, weekPassExpiry: nil, proExpiry: nil)
        await dependencies.runtimeApplyQueue?.value
        #expect(dependencies.automationScheduleTask != nil)
        #expect(dependencies.isAutomationArmed)

        subscription.applyEntitlementState(tier: .weekPass, weekPassExpiry: nil, proExpiry: nil)
        await dependencies.runtimeApplyQueue?.value
        #expect(dependencies.automationScheduleTask == nil)
        #expect(!dependencies.isAutomationArmed)
    }
}
