// FeatureGatedView.swift — Generic wrapper that gates content behind subscription tier.

import Core
import Services
import SharedUI
import StoreKit
import SwiftUI

// MARK: - Feature Gated View

/// Displays content when the user has access to a feature, or a paywall overlay otherwise.
///
/// Uses `FeatureGate.canAccess` to determine visibility. When locked, delegates to
/// `PaywallOverlay` with pricing pulled from `SubscriptionService.products`.
struct FeatureGatedView<Content: View>: View {
    let feature: AppFeature
    @ViewBuilder let content: () -> Content
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        if dependencies.featureGate?.canAccess(feature) == true {
            content()
        } else {
            PaywallOverlay(
                lockedFeature: feature,
                currentTier: dependencies.subscriptionService?.currentTier ?? .free,
                weekPassAvailable: feature.minimumTier < .pro
                    && (dependencies.subscriptionService?.canPurchaseWeekPass ?? false),
                weekPassPrice: priceString(for: SubscriptionProductID.weekPass),
                proMonthlyPrice: priceString(for: SubscriptionProductID.proMonthly),
                proYearlyPrice: priceString(for: SubscriptionProductID.proYearly),
                onPurchaseWeekPass: { purchaseProduct(id: SubscriptionProductID.weekPass) },
                onPurchasePro: { purchaseProduct(id: SubscriptionProductID.proMonthly) },
                onRestore: { Task { await dependencies.subscriptionService?.restorePurchases() } }
            )
        }
    }

    // MARK: - Private Helpers

    private func priceString(for productID: String) -> String? {
        dependencies.subscriptionService?.products
            .first { $0.id == productID }?
            .displayPrice
    }

    private func purchaseProduct(id productID: String) {
        guard let product = dependencies.subscriptionService?.products
            .first(where: { $0.id == productID })
        else { return }
        Task {
            _ = try? await dependencies.subscriptionService?.purchase(product)
        }
    }
}
