// FeatureGate.swift — Centralized feature access control based on subscription tier.
//
// Two init paths:
// - Production: init(subscription:) reads tier from SubscriptionService
// - Testing: init(fixedTier:) bypasses StoreKit entirely

import Core
import Foundation
import OSLog

private let log = Logger(subsystem: "com.genreupdater", category: "FeatureGate")

// MARK: - FeatureGateError

public enum FeatureGateError: Error, Sendable {
    case featureRequiresTier(feature: AppFeature, required: Tier, current: Tier)
    case freeTrackLimitReached(limit: Int, used: Int)
}

extension FeatureGateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .featureRequiresTier(feature, required, current):
            return "\(feature.rawValue) requires \(required) tier. Current tier: \(current)."
        case let .freeTrackLimitReached(limit, used):
            let remaining = max(0, limit - used)
            let trackLabel = remaining == 1 ? "track" : "tracks"
            return "Free tier track limit reached. \(remaining) \(trackLabel) remaining out of \(limit). Upgrade to process more tracks."
        }
    }
}

// MARK: - FeatureGate

@MainActor
public final class FeatureGate {
    public static let freeTrackLimit = 500

    private let tierProvider: () -> Tier
    private let freeTracksUsedProvider: () -> Int

    // MARK: - Production Init

    /// Create a gate backed by a live SubscriptionService.
    ///
    /// - Parameters:
    ///   - tierProvider: Closure that returns the current tier (from SubscriptionService).
    ///   - freeTracksUsedProvider: Closure that returns the count of free tracks used.
    public init(
        tierProvider: @escaping () -> Tier,
        freeTracksUsedProvider: @escaping () -> Int = { 0 }
    ) {
        self.tierProvider = tierProvider
        self.freeTracksUsedProvider = freeTracksUsedProvider
    }

    /// Convenience: create a gate with a fixed tier (for tests and previews).
    public init(fixedTier: Tier, freeTracksUsed: Int = 0) {
        tierProvider = { fixedTier }
        freeTracksUsedProvider = { freeTracksUsed }
    }

    // MARK: - Public API

    public var currentTier: Tier {
        tierProvider()
    }

    /// Check whether the current tier can access a feature.
    public func canAccess(_ feature: AppFeature) -> Bool {
        currentTier >= feature.minimumTier
    }

    /// Require access to a feature; throws if the tier is insufficient.
    public func require(_ feature: AppFeature) throws {
        let tier = currentTier
        guard tier >= feature.minimumTier else {
            log.warning(
                "Access denied: \(feature.rawValue, privacy: .public) requires \(String(describing: feature.minimumTier), privacy: .public)"
            )
            throw FeatureGateError.featureRequiresTier(
                feature: feature,
                required: feature.minimumTier,
                current: tier
            )
        }
    }

    /// Check whether additional tracks can be processed on the free tier.
    ///
    /// Paid tiers always return true. Free tier checks against the 500-track lifetime limit.
    public func canProcessTracks(count: Int) -> Bool {
        guard currentTier == .free else { return true }
        return freeTracksUsedProvider() + count <= Self.freeTrackLimit
    }

    /// Require capacity for processing tracks; throws if free limit would be exceeded.
    public func requireTrackCapacity(count: Int) throws {
        let used = freeTracksUsedProvider()
        guard canProcessTracks(count: count) else {
            throw FeatureGateError.freeTrackLimitReached(
                limit: Self.freeTrackLimit,
                used: used
            )
        }
    }

    /// Require capacity for a track collection, counting duplicate IDs once.
    @discardableResult
    public func requireTrackCapacity(for tracks: [Track]) throws -> Int {
        let uniqueTrackCount = Set(tracks.map(\.id)).count
        try requireTrackCapacity(count: uniqueTrackCount)
        return uniqueTrackCount
    }

    /// All features accessible at the current tier.
    public func accessibleFeatures() -> [AppFeature] {
        let tier = currentTier
        return AppFeature.allCases.filter { tier >= $0.minimumTier }
    }

    /// All features locked at the current tier.
    public func lockedFeatures() -> [AppFeature] {
        let tier = currentTier
        return AppFeature.allCases.filter { tier < $0.minimumTier }
    }
}
