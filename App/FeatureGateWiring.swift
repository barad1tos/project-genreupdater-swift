import Core
import Services

extension AppDependencies {
    static func makeFeatureGate(
        for subscription: SubscriptionService,
        fixedTier: Tier? = nil
    ) -> FeatureGate {
        FeatureGate(
            tierProvider: { fixedTier ?? subscription.currentTier },
            freeTracksUsedProvider: { subscription.freeTracksUsed },
            usageRecorder: { count in
                subscription.incrementFreeTracksUsed(by: count)
            }
        )
    }
}
