import Foundation
import Testing
@testable import Core

@Suite("Mirror state")
struct MirrorStateTests {
    private let membershipFingerprint = String(repeating: "a", count: 64)

    @Test("Initial revision starts at zero")
    func initialRevisionStartsAtZero() {
        #expect(MirrorRevision.initial.value == 0)
    }

    @Test("Advancing a revision increments it exactly once")
    func advancingRevisionIncrementsOnce() throws {
        let revision = MirrorRevision(value: 41)

        #expect(try revision.advanced() == MirrorRevision(value: 42))
    }

    @Test("Revision ordering follows its monotonic value")
    func revisionOrderingIsMonotonic() throws {
        let first = MirrorRevision.initial
        let second = try first.advanced()
        let third = try second.advanced()

        #expect(first < second)
        #expect(second < third)
        #expect(first < third)
    }

    @Test("Advancing the maximum revision returns a recoverable error")
    func maximumRevisionIsRecoverable() {
        let revision = MirrorRevision(value: .max)

        #expect(throws: MirrorRevisionExhausted(revision: revision)) {
            try revision.advanced()
        }
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

    @Test("Membership stamps accept a canonical SHA-256 fingerprint")
    func acceptsCanonicalStamp() throws {
        let stamp = try MembershipStamp(fingerprint: membershipFingerprint)

        #expect(stamp.fingerprint == membershipFingerprint)
    }

    @Test("Membership stamps reject noncanonical fingerprints", arguments: [
        "",
        String(repeating: "a", count: 63),
        String(repeating: "A", count: 64),
        String(repeating: "z", count: 64),
    ])
    func rejectsNoncanonicalStamp(fingerprint: String) {
        #expect(throws: MembershipStampError.invalidFingerprint) {
            try MembershipStamp(fingerprint: fingerprint)
        }
    }

    @Test("Membership stamp decoding preserves fingerprint validation")
    func validatesDecodedStamp() throws {
        let encoded = try JSONEncoder().encode(["fingerprint": "invalid"])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MembershipStamp.self, from: encoded)
        }
    }

    @Test("Synchronization audit rejects negative delta counts")
    func syncAuditRejectsNegativeDelta() throws {
        #expect(throws: MirrorSyncRecordValidationError.negativeDeltaCount) {
            try syncRecord(delta: MirrorSyncCounts(
                new: -1,
                modified: 0,
                identityChanged: 0,
                refreshed: 0,
                removed: 0
            ))
        }
    }

    @Test("Synchronization audit rejects impossible coverage")
    func syncAuditRejectsImpossibleCoverage() throws {
        #expect(throws: MirrorSyncRecordValidationError.invalidCoverageCount) {
            try syncRecord(coverage: MirrorSyncCoverage(
                identityRequestedCount: 1,
                identityObservedCount: 2,
                metadataRequestedCount: 0,
                metadataObservedCount: 0,
                isMembershipComplete: true,
                isIdentityComplete: false,
                isMetadataComplete: true
            ))
        }
    }

    @Test("Synchronization audit rejects contradictory completeness")
    func syncAuditRejectsContradictoryCompleteness() throws {
        #expect(throws: MirrorSyncRecordValidationError.inconsistentCompleteness) {
            try syncRecord(coverage: MirrorSyncCoverage(
                identityRequestedCount: 1,
                identityObservedCount: 0,
                metadataRequestedCount: 1,
                metadataObservedCount: 0,
                isMembershipComplete: true,
                isIdentityComplete: true,
                isMetadataComplete: false
            ))
        }
    }

    @Test("Synchronization window preserves the legacy completedAt wire key")
    func syncWindowPreservesLegacyWireKey() throws {
        let encoded = try JSONEncoder().encode(MirrorSyncWindow(
            startedAt: Date(timeIntervalSince1970: 100),
            preparedAt: Date(timeIntervalSince1970: 101)
        ))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["completedAt"] != nil)
        #expect(object["preparedAt"] == nil)

        let decoded = try JSONDecoder().decode(MirrorSyncWindow.self, from: encoded)
        #expect(decoded.preparedAt == Date(timeIntervalSince1970: 101))
    }

    @Test("Synchronization audit decoding enforces semantic validation")
    func syncAuditDecodingEnforcesValidation() throws {
        let encoded = try JSONEncoder().encode(syncRecord())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var delta = try #require(object["delta"] as? [String: Any])
        delta["new"] = -1
        object["delta"] = delta
        let invalidData = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: MirrorSyncRecordValidationError.negativeDeltaCount) {
            try JSONDecoder().decode(MirrorSyncRecord.self, from: invalidData)
        }
    }

    private func syncRecord(
        delta: MirrorSyncCounts = MirrorSyncCounts(
            new: 0,
            modified: 0,
            identityChanged: 0,
            refreshed: 0,
            removed: 0
        ),
        coverage: MirrorSyncCoverage = MirrorSyncCoverage(
            identityRequestedCount: 0,
            identityObservedCount: 0,
            metadataRequestedCount: 0,
            metadataObservedCount: 0,
            isMembershipComplete: true,
            isIdentityComplete: true,
            isMetadataComplete: true
        )
    ) throws -> MirrorSyncRecord {
        try MirrorSyncRecord(
            observation: ObservationID(),
            revisions: MirrorSyncRevisions(base: .initial, committed: MirrorRevision(value: 1)),
            evidence: MirrorSyncEvidence(
                membership: MembershipStamp(fingerprint: membershipFingerprint),
                scopeID: UUID(),
                certificateID: nil
            ),
            mode: .fast,
            window: MirrorSyncWindow(
                startedAt: Date(timeIntervalSince1970: 100),
                preparedAt: Date(timeIntervalSince1970: 101)
            ),
            delta: delta,
            coverage: coverage
        )
    }
}
