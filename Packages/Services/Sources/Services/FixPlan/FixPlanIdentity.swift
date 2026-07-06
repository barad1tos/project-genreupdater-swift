import Foundation

public struct FixPlanID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString
    }
}

public struct FixPlanRevision: Hashable, Comparable, Sendable, Codable {
    public static let initial = Self(1)

    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public func advanced() -> Self {
        Self(value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

/// Distinct from `FixPlanRevision` on purpose: write commands carry `planRevision`
/// and `decisionRevision` side by side, and swapping them must be a type error.
public struct ReviewDecisionRevision: Hashable, Comparable, Sendable, Codable {
    public static let initial = Self(1)

    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public func advanced() -> Self {
        Self(value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}
