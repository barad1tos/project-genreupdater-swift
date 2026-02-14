// TrackStatus.swift — Track status classification and editability
// Ported from: src/core/models/track_status.py (118 LOC) + types.py (32 LOC)
//
// Swift enum replaces Python frozensets + function-based classification.
// AppleScript raw constant mapping preserved for Music.app interop.

import Foundation

/// All possible statuses a track can have in Music.app.
///
/// Maps 1:1 to Apple Music's `kind` property. AppleScript sometimes returns
/// raw enum constants (e.g., "ksub") instead of string values — `init(rawConstant:)`
/// handles this translation.
public enum TrackKind: String, Sendable, CaseIterable, Codable, CustomStringConvertible {
    case localOnly = "local only"
    case purchased = "purchased"
    case matched = "matched"
    case uploaded = "uploaded"
    case subscription = "subscription"
    case downloaded = "downloaded"
    case prerelease = "prerelease"

    /// Human-readable description for UI display.
    public var description: String {
        switch self {
        case .localOnly: "Local Only"
        case .purchased: "Purchased"
        case .matched: "Matched"
        case .uploaded: "Uploaded"
        case .subscription: "Subscription"
        case .downloaded: "Downloaded"
        case .prerelease: "Pre-release"
        }
    }

    /// Whether this track's metadata can be edited.
    ///
    /// Prerelease tracks are read-only in Music.app — attempting to write
    /// to them via AppleScript will fail silently or error.
    public var canEditMetadata: Bool {
        self != .prerelease
    }

    /// Whether this track is available for standard genre/year processing.
    ///
    /// Only non-prerelease statuses with known values are considered available.
    public var isAvailableForProcessing: Bool {
        switch self {
        case .localOnly, .purchased, .matched, .uploaded, .subscription, .downloaded:
            return true
        case .prerelease:
            return false
        }
    }

    /// Initialize from an AppleScript raw enum constant.
    ///
    /// AppleScript sometimes returns raw constants like `«constant ****kSub»`
    /// instead of the string "subscription". This extracts the 4-char code
    /// and maps it to the proper status.
    ///
    /// - Parameter rawConstant: Raw AppleScript constant string (case-insensitive)
    /// - Returns: Mapped TrackKind, or nil if not recognized
    public init?(rawConstant: String) {
        let lowered = rawConstant.lowercased()

        // Map 4-char AppleScript codes to TrackKind
        let appleScriptMapping: [String: TrackKind] = [
            "ksub": .subscription,
            "kpre": .prerelease,
            "kloc": .localOnly,
            "kpur": .purchased,
            "kmat": .matched,
            "kupl": .uploaded,
            "kdwn": .downloaded,
        ]

        if let mapped = appleScriptMapping.first(where: { lowered.contains($0.key) })?.value {
            self = mapped
            return
        }

        return nil
    }
}

// MARK: - Status Normalization

/// Normalize a raw status string from Music.app into a `TrackKind`.
///
/// Handles:
/// - Regular status strings ("subscription", "purchased", etc.)
/// - AppleScript raw enum constants ("«constant ****kSub»")
/// - Case-insensitive matching
/// - nil/empty input
///
/// - Parameter rawStatus: Raw status string from AppleScript output
/// - Returns: Normalized TrackKind, or nil if status is empty/unrecognized
public func normalizeTrackStatus(_ rawStatus: String?) -> TrackKind? {
    guard let rawStatus, !rawStatus.isEmpty else { return nil }

    let trimmed = rawStatus.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.isEmpty { return nil }

    // Try direct rawValue match first
    if let kind = TrackKind(rawValue: trimmed) {
        return kind
    }

    // Try AppleScript constant extraction
    if trimmed.contains("constant") {
        return TrackKind(rawConstant: trimmed)
    }

    return nil
}

/// Filter tracks that are available for processing based on status.
public func filterAvailableTracks(_ tracks: [Track]) -> [Track] {
    tracks.filter { track in
        guard let kind = normalizeTrackStatus(track.trackStatus) else { return false }
        return kind.isAvailableForProcessing
    }
}
