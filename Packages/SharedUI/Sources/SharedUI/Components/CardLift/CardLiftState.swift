// CardLiftState.swift -- State machine for card lift interaction lifecycle.

import SwiftUI

// MARK: - Card Lift Phase

/// Animation phase for the card lift interaction.
///
/// Progression: `.idle` -> `.pressing` -> `.lifted` -> `.dismissing` -> `.idle`
public enum CardLiftPhase: Equatable, Sendable {
    /// No card interaction active.
    case idle
    /// Double-click detected; card is pressing in (scale 0.97).
    case pressing
    /// Card has lifted to center with spring animation.
    case lifted
    /// Card is animating back to source position.
    case dismissing
}

// MARK: - Card Content Type

/// Content type carried by a lifted card, determines glow color and layout.
public enum CardContentType: Equatable, Sendable, Hashable {
    /// Artist card with album list and statistics.
    case artist(name: String)
    /// Album card with tracklist and metadata.
    case album(name: String, artistName: String)
}

// MARK: - Card Lift State

/// Complete state for a card lift interaction including source position and cascade context.
///
/// Uses flat fields for parent state instead of recursive struct to maintain `Sendable` conformance.
public struct CardLiftState: Equatable, Sendable {
    /// Unique identifier of the source row that triggered the lift.
    public let sourceID: String

    /// Content type displayed in the lifted card.
    public let contentType: CardContentType

    /// Current animation phase.
    public var phase: CardLiftPhase

    /// Frame of the source row in the container's coordinate space.
    public var sourceFrame: CGRect

    // MARK: Cascade Parent (flat fields)

    /// Source ID of the parent card in a cascade (Artist -> Album drill-down).
    public let parentSourceID: String?

    /// Content type of the parent card.
    public let parentContentType: CardContentType?

    /// Source frame of the parent card.
    public let parentSourceFrame: CGRect?

    public init(
        sourceID: String,
        contentType: CardContentType,
        phase: CardLiftPhase = .pressing,
        sourceFrame: CGRect = .zero,
        parentSourceID: String? = nil,
        parentContentType: CardContentType? = nil,
        parentSourceFrame: CGRect? = nil
    ) {
        self.sourceID = sourceID
        self.contentType = contentType
        self.phase = phase
        self.sourceFrame = sourceFrame
        self.parentSourceID = parentSourceID
        self.parentContentType = parentContentType
        self.parentSourceFrame = parentSourceFrame
    }

    /// Whether this lift has a cascade parent to return to on dismiss.
    public var hasCascadeParent: Bool {
        parentSourceID != nil
    }
}

// MARK: - Card Glow Color

/// Maps card content types to their neon glow colors.
public enum CardGlowColor {
    /// Returns the glow color for a given content type.
    ///
    /// Artist cards use the primary accent (orange/gold), album cards use info (cyan/blue)
    /// for visual hierarchy distinction.
    public static func forContentType(_ type: CardContentType) -> Color {
        switch type {
        case .artist: Ayu.accent
        case .album: Ayu.info
        }
    }
}
