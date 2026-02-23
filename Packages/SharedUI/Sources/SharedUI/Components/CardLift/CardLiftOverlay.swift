// CardLiftOverlay.swift -- Full overlay container for card lift interaction.

import SwiftUI

// MARK: - Card Lift Overlay

/// Full-screen overlay that displays a lifted card with dim background and neon glow.
///
/// Renders three layers in a ZStack:
/// 1. Dim overlay (Color.black at 0.6 opacity) with tap-to-dismiss
/// 2. Card content with scale, offset, glow border, and shadow
/// 3. Spring animation driven by `CardLiftPhase` changes
///
/// Supports Escape key dismissal via `.onKeyPress`. Content is visible immediately
/// with the lift -- no delayed fade-in.
public struct CardLiftOverlay<Content: View>: View {
    private let state: CardLiftState
    private let containerSize: CGSize
    private let onDismiss: () -> Void
    @ViewBuilder private let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: CardLiftState,
        containerSize: CGSize,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.state = state
        self.containerSize = containerSize
        self.onDismiss = onDismiss
        self.content = content
    }

    // MARK: Computed Properties

    /// Adaptive card width: 70% of container, max 600pt.
    private var cardWidth: CGFloat {
        min(containerSize.width * 0.7, 600)
    }

    private var isLifted: Bool {
        state.phase == .lifted
    }

    private var isPressing: Bool {
        state.phase == .pressing
    }

    private var scaleValue: CGFloat {
        switch state.phase {
        case .pressing: 0.97
        case .lifted: 1.03
        case .dismissing, .idle: 1.0
        }
    }

    /// Vertical offset to animate card from source row position to center.
    private var offsetForPhase: CGFloat {
        let containerCenterY = containerSize.height / 2
        let sourceCenterY = state.sourceFrame.midY

        switch state.phase {
        case .lifted:
            return 0
        case .pressing, .idle, .dismissing:
            return sourceCenterY - containerCenterY
        }
    }

    // MARK: Body

    public var body: some View {
        ZStack {
            Color.black
                .opacity(isLifted || isPressing ? 0.6 : 0)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            content()
                .frame(maxWidth: cardWidth)
                .background(
                    Ayu.bgPrimary,
                    in: RoundedRectangle(cornerRadius: Radius.lg)
                )
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .overlay {
                    NeonGlowBorder(
                        color: CardGlowColor.forContentType(state.contentType),
                        cornerRadius: Radius.lg
                    )
                }
                .ayuShadow(Shadow.floating)
                .scaleEffect(scaleValue)
                .offset(y: offsetForPhase)
        }
        .animation(reduceMotion ? nil : Motion.cardLiftSpring, value: state.phase)
        .focusable()
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }
}
