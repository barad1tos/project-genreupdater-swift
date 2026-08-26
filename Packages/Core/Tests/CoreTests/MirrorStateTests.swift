import Foundation
import Testing
@testable import Core

@Suite("Mirror state")
struct MirrorStateTests {
    @Test("Initial revision starts at zero")
    func initialRevisionStartsAtZero() {
        #expect(MirrorRevision.initial.value == 0)
    }

    @Test("Advancing a revision increments it exactly once")
    func advancingRevisionIncrementsOnce() {
        let revision = MirrorRevision(value: 41)

        #expect(revision.advanced() == MirrorRevision(value: 42))
    }

    @Test("Revision ordering follows its monotonic value")
    func revisionOrderingIsMonotonic() {
        let first = MirrorRevision.initial
        let second = first.advanced()
        let third = second.advanced()

        #expect(first < second)
        #expect(second < third)
        #expect(first < third)
    }

    @Test("Revision Codable preserves numeric boundaries", arguments: [UInt64.min, UInt64.max])
    func revisionCodablePreservesBoundaries(value: UInt64) throws {
        let revision = MirrorRevision(value: value)

        let data = try JSONEncoder().encode(revision)
        let decoded = try JSONDecoder().decode(MirrorRevision.self, from: data)

        #expect(decoded == revision)
    }

    @Test("Revision conflicts describe the stale and current revisions")
    func conflictDescription() {
        let conflict = MirrorRevisionConflict(
            expected: MirrorRevision(value: 4),
            actual: MirrorRevision(value: 7)
        )

        #expect(conflict.localizedDescription == "Mirror revision conflict: expected 4, current 7.")
    }
}
