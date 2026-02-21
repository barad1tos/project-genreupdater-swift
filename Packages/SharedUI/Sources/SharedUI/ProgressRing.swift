// ProgressRing.swift — Circular progress indicator with percentage label.

import SwiftUI

// MARK: - ProgressRing

/// Circular progress ring with a centered percentage label and optional message.
///
/// Animates the arc trim when the progress value changes.
public struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let message: String?

    /// Creates a circular progress ring.
    ///
    /// - Parameters:
    ///   - progress: Value between 0.0 and 1.0 representing completion.
    ///   - lineWidth: Stroke width of the ring. Defaults to 8.
    ///   - message: Optional descriptive text displayed below the ring.
    public init(progress: Double, lineWidth: CGFloat = 8, message: String? = nil) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                trackCircle
                progressArc
                percentageLabel
            }
            .frame(width: ringSize, height: ringSize)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(clampedProgress * 100)) percent")
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Subviews

    private var trackCircle: some View {
        Circle()
            .stroke(.quaternary, lineWidth: lineWidth)
    }

    private var progressArc: some View {
        Circle()
            .trim(from: 0, to: clampedProgress)
            .stroke(
                progressGradient,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .animation(.easeInOut(duration: 0.4), value: clampedProgress)
    }

    private var percentageLabel: some View {
        Text("\(Int(clampedProgress * 100))%")
            .font(.system(.title3, design: .rounded))
            .bold()
            .foregroundStyle(.primary)
            .contentTransition(.numericText())
    }

    // MARK: - Private Helpers

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var ringSize: CGFloat {
        80 + lineWidth * 2
    }

    private var progressGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [.blue, .purple]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360 * clampedProgress)
        )
    }

    private var accessibilityDescription: String {
        if let message {
            "Progress: \(message)"
        } else {
            "Progress"
        }
    }
}

// MARK: - Preview

#Preview("Progress Ring States") {
    VStack(spacing: 24) {
        ProgressRing(progress: 0.0, message: "Not started")
        ProgressRing(progress: 0.45, message: "Processing tracks...")
        ProgressRing(progress: 1.0, lineWidth: 12, message: "Complete")
    }
    .padding()
}
