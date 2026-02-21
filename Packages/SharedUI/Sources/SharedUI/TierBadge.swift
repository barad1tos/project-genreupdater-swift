// TierBadge.swift — Subscription tier badge.

import Core
import SwiftUI

// MARK: - TierBadge

/// Small capsule badge displaying the user's subscription tier.
///
/// Colors reflect the tier level:
/// - Free: gray
/// - Week Pass: blue
/// - Pro: gold
public struct TierBadge: View {
    let tier: Tier

    /// Creates a tier badge.
    ///
    /// - Parameter tier: The subscription tier to display.
    public init(tier: Tier) {
        self.tier = tier
    }

    public var body: some View {
        Text(tier.displayName)
            .font(.caption2)
            .bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tier.badgeColor, in: .capsule)
            .accessibilityLabel("\(tier.displayName) tier")
    }
}

// MARK: - Tier Display Helpers

extension Tier {
    public var displayName: String {
        switch self {
        case .free:
            "Free"
        case .weekPass:
            "Week Pass"
        case .pro:
            "Pro"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .free:
            .gray
        case .weekPass:
            .blue
        case .pro:
            .yellow
        }
    }
}

// MARK: - Preview

#Preview("All Tiers") {
    HStack(spacing: 12) {
        TierBadge(tier: .free)
        TierBadge(tier: .weekPass)
        TierBadge(tier: .pro)
    }
    .padding()
}
