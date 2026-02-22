// ConfidenceBadge.swift — Color-coded badge showing confidence percentage.

import SwiftUI

// MARK: - ConfidenceBadge

/// Displays a confidence value as a color-coded capsule badge.
///
/// The badge color reflects the confidence level:
/// - Green for high confidence (80% and above)
/// - Yellow for moderate confidence (50% to 79%)
/// - Red for low confidence (below 50%)
public struct ConfidenceBadge: View {
    let confidence: Double

    /// Creates a confidence badge.
    ///
    /// - Parameter confidence: Value between 0.0 and 1.0 representing confidence level.
    public init(confidence: Double) {
        self.confidence = confidence
    }

    public var body: some View {
        Text(formattedPercentage)
            .font(.caption2)
            .bold()
            .foregroundStyle(badgeForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor, in: .capsule)
            .accessibilityLabel(
                "\(Int(clampedConfidence * 100)) percent confidence"
            )
    }

    // MARK: - Private Helpers

    private var clampedConfidence: Double {
        min(max(confidence, 0), 1)
    }

    private var formattedPercentage: String {
        "\(Int(clampedConfidence * 100))%"
    }

    private var badgeForeground: Color {
        Ayu.confidenceForeground(clampedConfidence)
    }

    private var badgeColor: Color {
        Ayu.confidence(clampedConfidence)
    }
}

// MARK: - Preview

#Preview("Confidence Levels") {
    HStack(spacing: 12) {
        ConfidenceBadge(confidence: 0.95)
        ConfidenceBadge(confidence: 0.65)
        ConfidenceBadge(confidence: 0.30)
    }
    .padding()
}
