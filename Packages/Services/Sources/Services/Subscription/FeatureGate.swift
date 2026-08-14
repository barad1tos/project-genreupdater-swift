// FeatureGate.swift — Centralized feature access control based on subscription tier.
//
// Production injects live tier, allowance, and persistence providers.
// Tests and previews can use a fixed tier without StoreKit.

import Core
import Foundation
import OSLog

private let log = Logger(subsystem: "com.genreupdater", category: "FeatureGate")

struct WriteAdmission: Sendable {
    let tier: Tier
    let freeTracksUsed: Int

    func canAccess(_ feature: AppFeature) -> Bool {
        tier >= feature.minimumTier
    }

    func require(_ feature: AppFeature) throws {
        guard canAccess(feature) else {
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

    func canProcessTracks(count: Int) -> Bool {
        tier != .free || freeTracksUsed + count <= FeatureGate.freeTrackLimit
    }

    func requireTrackCapacity(count: Int) throws {
        guard canProcessTracks(count: count) else {
            throw FeatureGateError.freeTrackLimitReached(
                limit: FeatureGate.freeTrackLimit,
                used: freeTracksUsed
            )
        }
    }
}

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
    nonisolated public static let freeTrackLimit = 500

    private let tierProvider: () -> Tier
    private let freeTracksUsedProvider: () -> Int
    private let usageRecorder: (Int) -> Void

    // MARK: - Production Init

    /// Create a gate backed by a live SubscriptionService.
    ///
    /// - Parameters:
    ///   - tierProvider: Closure that returns the current tier (from SubscriptionService).
    ///   - freeTracksUsedProvider: Closure that returns the count of free tracks used.
    ///   - usageRecorder: Closure that persists successful free-tier track usage.
    public init(
        tierProvider: @escaping () -> Tier,
        freeTracksUsedProvider: @escaping () -> Int,
        usageRecorder: @escaping (Int) -> Void
    ) {
        self.tierProvider = tierProvider
        self.freeTracksUsedProvider = freeTracksUsedProvider
        self.usageRecorder = usageRecorder
    }

    /// Convenience: create a gate with a fixed tier (for tests and previews).
    public init(
        fixedTier: Tier,
        freeTracksUsed: Int = 0,
        usageRecorder: @escaping (Int) -> Void = { _ in
            // Fixed-tier previews and tests opt in when they need persistent usage effects.
        }
    ) {
        tierProvider = { fixedTier }
        freeTracksUsedProvider = { freeTracksUsed }
        self.usageRecorder = usageRecorder
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
        try writeAdmission().require(feature)
    }

    /// Require capacity for processing tracks; throws if free limit would be exceeded.
    public func requireTrackCapacity(count: Int) throws {
        try writeAdmission().requireTrackCapacity(count: count)
    }

    /// Require capacity for a track collection, counting duplicate IDs once.
    @discardableResult
    public func requireTrackCapacity(for tracks: [Track]) throws -> Int {
        let uniqueTrackCount = Set(tracks.map(\.id)).count
        try requireTrackCapacity(count: uniqueTrackCount)
        return uniqueTrackCount
    }

    func writeAdmission() -> WriteAdmission {
        WriteAdmission(tier: currentTier, freeTracksUsed: freeTracksUsedProvider())
    }

    func recordTrackUsage(for trackIDs: Set<String>, admission: WriteAdmission) {
        guard admission.tier == .free, !trackIDs.isEmpty else { return }
        usageRecorder(trackIDs.count)
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
