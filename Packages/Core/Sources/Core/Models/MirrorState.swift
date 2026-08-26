/// Monotonic local commit sequence for mirror-affecting mutations.
public struct MirrorRevision: Codable, Comparable, Hashable, Sendable {
    public static let initial = Self(value: 0)

    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    public func advanced() -> Self {
        precondition(value < UInt64.max, "Mirror revision exhausted")
        return Self(value: value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

/// A mirror update was planned from a revision that is no longer current.
public struct MirrorRevisionConflict: Error, Equatable, Sendable {
    public let expected: MirrorRevision
    public let actual: MirrorRevision

    public init(expected: MirrorRevision, actual: MirrorRevision) {
        self.expected = expected
        self.actual = actual
    }
}
