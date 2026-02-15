// Tier.swift — Subscription tier levels for feature gating.

public enum Tier: Int, Comparable, Sendable, CaseIterable {
    case free = 0
    case weekPass = 1
    case pro = 2

    public static func < (lhs: Tier, rhs: Tier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
