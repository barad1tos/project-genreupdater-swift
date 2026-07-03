import Foundation

public struct ProjectionRevision: Equatable, Comparable, Hashable, Sendable {
    public static let initial = Self(0)

    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public func advanced() -> Self {
        Self(value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}
