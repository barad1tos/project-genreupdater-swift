// PaywallOverlay.swift — Blurred overlay for feature-gated content.

import Core
import SwiftUI

// MARK: - PaywallOverlay

/// Semi-transparent overlay that blocks access to locked features.
///
/// Displays the required tier, pricing options, and purchase buttons.
/// The Week Pass button is hidden when unavailable or when the feature
/// requires the Pro tier.
public struct PaywallOverlay: View {
    let lockedFeature: AppFeature
    let currentTier: Tier
    let weekPassAvailable: Bool
    let weekPassPrice: String?
    let proMonthlyPrice: String?
    let proYearlyPrice: String?
    let onPurchaseWeekPass: (() -> Void)?
    let onPurchasePro: (() -> Void)?
    let onRestore: (() -> Void)?

    /// Creates a paywall overlay for a locked feature.
    ///
    /// - Parameters:
    ///   - lockedFeature: The feature the user is trying to access.
    ///   - currentTier: The user's current subscription tier.
    ///   - weekPassAvailable: Whether the Week Pass option should be shown.
    ///   - weekPassPrice: Localized price string for the Week Pass (e.g., "$1.99").
    ///   - proMonthlyPrice: Localized monthly price for Pro (e.g., "$4.99/mo").
    ///   - proYearlyPrice: Localized yearly price for Pro (e.g., "$39.99/yr").
    ///   - onPurchaseWeekPass: Callback when the user taps the Week Pass button.
    ///   - onPurchasePro: Callback when the user taps the Pro button.
    ///   - onRestore: Callback when the user taps Restore Purchases.
    public init(
        lockedFeature: AppFeature,
        currentTier: Tier,
        weekPassAvailable: Bool = true,
        weekPassPrice: String? = nil,
        proMonthlyPrice: String? = nil,
        proYearlyPrice: String? = nil,
        onPurchaseWeekPass: (() -> Void)? = nil,
        onPurchasePro: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil
    ) {
        self.lockedFeature = lockedFeature
        self.currentTier = currentTier
        self.weekPassAvailable = weekPassAvailable
        self.weekPassPrice = weekPassPrice
        self.proMonthlyPrice = proMonthlyPrice
        self.proYearlyPrice = proYearlyPrice
        self.onPurchaseWeekPass = onPurchaseWeekPass
        self.onPurchasePro = onPurchasePro
        self.onRestore = onRestore
    }

    public var body: some View {
        VStack(spacing: 20) {
            lockIcon
            titleSection
            tierComparison
            purchaseButtons
            restoreButton
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: 400)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: Radius.xl))
        .padding()
    }

    // MARK: - Subviews

    private var lockIcon: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text("Unlock \(lockedFeature.displayName)")
                .font(.title2)
                .bold()

            Text("This feature requires the \(requiredTier.displayName) plan or higher.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var tierComparison: some View {
        HStack(spacing: 16) {
            TierComparisonColumn(
                label: "Current",
                tier: currentTier
            )

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)

            TierComparisonColumn(
                label: "Required",
                tier: requiredTier
            )
        }
        .padding(.vertical, 8)
    }

    private var purchaseButtons: some View {
        VStack(spacing: 12) {
            if shouldShowWeekPass {
                Button {
                    onPurchaseWeekPass?()
                } label: {
                    VStack(spacing: 2) {
                        Text("Week Pass")
                            .bold()
                        if let weekPassPrice {
                            Text(weekPassPrice)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Double-tap to purchase")
            }

            if let onPurchasePro {
                Button {
                    onPurchasePro()
                } label: {
                    VStack(spacing: 2) {
                        Text("Go Pro")
                            .bold()
                        proPricingLabel
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Double-tap to purchase")
            }
        }
    }

    private var restoreButton: some View {
        Group {
            if let onRestore {
                Button("Restore Purchases", action: onRestore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Private Helpers

    private var requiredTier: Tier {
        lockedFeature.minimumTier
    }

    private var shouldShowWeekPass: Bool {
        weekPassAvailable
            && lockedFeature.minimumTier != .pro
            && onPurchaseWeekPass != nil
    }

    @ViewBuilder
    private var proPricingLabel: some View {
        if let proMonthlyPrice, let proYearlyPrice {
            Text("\(proMonthlyPrice) or \(proYearlyPrice)")
                .font(.caption)
        } else if let proMonthlyPrice {
            Text(proMonthlyPrice)
                .font(.caption)
        } else if let proYearlyPrice {
            Text(proYearlyPrice)
                .font(.caption)
        }
    }
}

// MARK: - TierComparisonColumn

/// Column showing a tier label and badge for the paywall comparison.
struct TierComparisonColumn: View {
    let label: String
    let tier: Tier

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TierBadge(tier: tier)
        }
    }
}

// MARK: - AppFeature Display Helpers

extension AppFeature {
    public var displayName: String {
        switch self {
        case .genreUpdate:
            "Genre Update"
        case .yearUpdate:
            "Year Update"
        case .preview:
            "Preview"
        case .undo:
            "Undo"
        case .libraryBrowsing:
            "Library Browsing"
        case .basicCaching:
            "Basic Caching"
        case .batchProcessing:
            "Batch Processing"
        case .reportsLog:
            "Reports Log"
        case .reportsCharts:
            "Reports Charts"
        case .csvExport:
            "CSV Export"
        case .artistAlbumCleaning:
            "Artist & Album Cleaning"
        case .advancedCache:
            "Advanced Cache"
        case .autoSync:
            "Auto Sync"
        }
    }
}

// MARK: - Preview

#Preview("Paywall - Week Pass Feature") {
    PaywallOverlay(
        lockedFeature: .batchProcessing,
        currentTier: .free,
        weekPassAvailable: true,
        weekPassPrice: "$1.99",
        proMonthlyPrice: "$4.99/mo",
        proYearlyPrice: "$39.99/yr",
        onPurchaseWeekPass: {},
        onPurchasePro: {},
        onRestore: {}
    )
}

#Preview("Paywall - Pro-Only Feature") {
    PaywallOverlay(
        lockedFeature: .autoSync,
        currentTier: .weekPass,
        weekPassAvailable: true,
        proMonthlyPrice: "$4.99/mo",
        proYearlyPrice: "$39.99/yr",
        onPurchasePro: {},
        onRestore: {}
    )
}
