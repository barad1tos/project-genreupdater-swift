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

public struct FixPlanWriteTarget: Equatable, Sendable {
    public let planID: FixPlanID
    public let planRevision: FixPlanRevision
    public let decisionRevision: ReviewDecisionRevision

    public init(
        planID: FixPlanID,
        planRevision: FixPlanRevision,
        decisionRevision: ReviewDecisionRevision
    ) {
        self.planID = planID
        self.planRevision = planRevision
        self.decisionRevision = decisionRevision
    }
}

public struct FixPlanWriteInput: Equatable, Sendable {
    public let target: FixPlanWriteTarget
    public let scope: ProcessingScopeSnapshot

    public init(
        target: FixPlanWriteTarget,
        scope: ProcessingScopeSnapshot
    ) {
        self.target = target
        self.scope = scope
    }
}
