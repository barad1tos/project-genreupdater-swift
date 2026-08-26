import Foundation

/// A canonical library-membership fingerprint produced from Music database IDs.
public struct MembershipStamp: Codable, Equatable, Hashable, Sendable {
    public let fingerprint: String

    public init(fingerprint: String) throws {
        guard Self.isCanonical(fingerprint) else {
            throw MembershipStampError.invalidFingerprint
        }
        self.fingerprint = fingerprint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fingerprint = try container.decode(String.self, forKey: .fingerprint)
        do {
            try self.init(fingerprint: fingerprint)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .fingerprint,
                in: container,
                debugDescription: "Membership fingerprint must be 64 lowercase hexadecimal characters."
            )
        }
    }

    private static func isCanonical(_ fingerprint: String) -> Bool {
        fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

/// A membership fingerprint does not use the canonical SHA-256 representation.
enum MembershipStampError: Error, Equatable, Sendable {
    case invalidFingerprint
}

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
