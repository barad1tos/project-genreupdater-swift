import Foundation

/// Monotonic local commit sequence for mirror-affecting mutations.
public struct MirrorRevision: Codable, Comparable, Hashable, Sendable {
    public static let initial = Self(value: 0)

    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    public func advanced() throws -> Self {
        guard value < UInt64.max else {
            throw MirrorRevisionExhausted(revision: self)
        }
        return Self(value: value + 1)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

/// The local mirror commit sequence cannot represent another revision.
struct MirrorRevisionExhausted: LocalizedError, Equatable, Sendable {
    let revision: MirrorRevision

    var errorDescription: String? {
        "Mirror revision exhausted at \(revision.value)."
    }
}

/// A mirror update was planned from a revision that is no longer current.
public struct MirrorRevisionConflict: LocalizedError, Equatable, Sendable {
    public let expected: MirrorRevision
    public let actual: MirrorRevision

    public init(expected: MirrorRevision, actual: MirrorRevision) {
        self.expected = expected
        self.actual = actual
    }

    public var errorDescription: String? {
        "Mirror revision conflict: expected \(expected.value), current \(actual.value)."
    }
}
