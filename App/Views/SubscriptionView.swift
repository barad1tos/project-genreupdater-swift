// SubscriptionView.swift — Standalone subscription management and purchase UI.

import Core
import Services
import SharedUI
import StoreKit
import SwiftUI

// MARK: - Subscription View

/// Full-screen subscription management view showing current tier, available products, and purchase actions.
///
/// Displays pricing from `SubscriptionService.products`, handles purchases via `purchase(_:)`,
/// and shows Week Pass cooldown status when applicable.
struct SubscriptionView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var purchaseError: String?
    @State private var isRestoring = false
    @State private var isPurchasing = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                currentTierSection
                productsSection
                weekPassCooldownSection
                restoreSection
                featureComparisonSection
            }
            .padding()
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Subscription")
        .alert("Purchase Error", isPresented: purchaseErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchaseError ?? "An unknown error occurred.")
        }
    }

    // MARK: - Current Tier Section

    private var currentTierSection: some View {
        VStack(spacing: Spacing.sm) {
            Text("Current Plan")
                .font(.headline)
                .foregroundStyle(.secondary)

            TierBadge(tier: currentTier)

            if currentTier == .free {
                Text("Free tier: \(freeTracksUsed) of \(FeatureGate.freeTrackLimit) tracks used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let proExpiry = dependencies.subscriptionService?.proExpiry, currentTier == .pro {
                Text("Renews \(proExpiry, format: .dateTime.month().day().year())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let weekPassExpiry = dependencies.subscriptionService?.weekPassExpiry,
               currentTier == .weekPass, weekPassExpiry > Date() {
                Text("Expires \(weekPassExpiry, format: .dateTime.month().day().year())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
    }

    // MARK: - Products Section

    private var productsSection: some View {
        VStack(spacing: Spacing.md) {
            Text("Available Plans")
                .font(.title3)
                .bold()

            if products.isEmpty {
                ProgressView("Loading products...")
            } else {
                ForEach(products, id: \.id) { product in
                    productRow(for: product)
                }
            }
        }
    }

    private func productRow(for product: Product) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(product.displayName)
                    .font(.headline)

                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                handlePurchase(product)
            } label: {
                Text(product.displayPrice)
                    .bold()
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPurchasing || !canPurchase(product))
        }
        .padding()
        .background(.background, in: .rect(cornerRadius: 12))
        .shadow(color: .primary.opacity(0.05), radius: 2, y: 1)
    }

    // MARK: - Week Pass Cooldown Section

    @ViewBuilder
    private var weekPassCooldownSection: some View {
        if let remaining = dependencies.subscriptionService?.weekPassCooldownRemaining {
            let cooldownEnd = Date().addingTimeInterval(remaining)
            VStack(spacing: Spacing.xs) {
                Label("Week Pass Cooldown Active", systemImage: "clock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)

                Text("Next purchase available \(cooldownEnd, format: .dateTime.month().day())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }

    // MARK: - Restore Section

    private var restoreSection: some View {
        Button {
            handleRestore()
        } label: {
            if isRestoring {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Restore Purchases")
            }
        }
        .disabled(isRestoring)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - Feature Comparison Section

    private var featureComparisonSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Feature Comparison")
                .font(.title3)
                .bold()

            ForEach(AppFeature.allCases, id: \.rawValue) { feature in
                HStack {
                    Image(systemName: currentTier >= feature.minimumTier
                        ? "checkmark.circle.fill" : "lock.fill")
                        .foregroundStyle(currentTier >= feature.minimumTier ? .green : .secondary)
                        .frame(width: 24)

                    Text(feature.displayName)
                        .font(.body)

                    Spacer()

                    TierBadge(tier: feature.minimumTier)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
    }

    // MARK: - Private Helpers

    private var currentTier: Tier {
        dependencies.subscriptionService?.currentTier ?? .free
    }

    private var freeTracksUsed: Int {
        dependencies.subscriptionService?.freeTracksUsed ?? 0
    }

    private var products: [Product] {
        dependencies.subscriptionService?.products ?? []
    }

    private var purchaseErrorBinding: Binding<Bool> {
        Binding(
            get: { purchaseError != nil },
            set: { isPresented in
                if !isPresented {
                    purchaseError = nil
                }
            }
        )
    }

    private func canPurchase(_ product: Product) -> Bool {
        if product.id == SubscriptionProductID.weekPass {
            return dependencies.subscriptionService?.canPurchaseWeekPass ?? false
        }
        return true
    }

    private func handlePurchase(_ product: Product) {
        isPurchasing = true
        Task {
            defer { isPurchasing = false }
            do {
                _ = try await dependencies.subscriptionService?.purchase(product)
            } catch {
                purchaseError = error.localizedDescription
            }
        }
    }

    private func handleRestore() {
        isRestoring = true
        Task {
            await dependencies.subscriptionService?.restorePurchases()
            isRestoring = false
        }
    }
}
