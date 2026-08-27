import Foundation
import Testing
@testable import Core

@Suite("Mirror readiness certificates")
struct MirrorReadinessTests {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private var currentMembership: MembershipStamp {
        membership(repeating: "a")
    }

    private var previousMembership: MembershipStamp {
        membership(repeating: "b")
    }

    @Test("An exact current certificate admits its processing requirement")
    func admitsExactCertificate() {
        let certificate = makeCertificate()
        let snapshot = makeSnapshot(certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .ready(certificate))
    }

    @Test("A certificate from another membership is stale")
    func rejectsChangedMembership() {
        let certificate = makeCertificate(membership: previousMembership)
        let snapshot = makeSnapshot(certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .stale(.membershipChanged))
    }

    @Test("Changed Test Artists require a fresh exact observation")
    func rejectsChangedTestArtists() {
        let snapshot = makeSnapshot(certificates: [makeCertificate(testArtists: ["Metallica", "Björk"])])

        #expect(snapshot.readiness(for: requirement()) == .incomplete(.freshObservationRequired))
    }

    @Test("A broader certificate does not admit a narrower artist request")
    func rejectsCrossGenerationArtistUnion() {
        let snapshot = makeSnapshot(certificates: [makeCertificate(testArtists: ["Metallica", "Björk"])])

        #expect(snapshot.readiness(for: requirement(testArtists: ["Metallica"])) ==
            .incomplete(.freshObservationRequired))
    }

    @Test("A certificate with incomplete requested IDs is inadmissible")
    func rejectsIncompleteRequestedIDs() {
        let certificate = makeCertificate(
            requestedFingerprint: String(repeating: "c", count: 64),
            observedFingerprint: String(repeating: "d", count: 64)
        )
        let snapshot = makeSnapshot(certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .incomplete(.metadataMissing(count: 1)))
    }

    @Test("A certificate outside the requirement freshness window is stale")
    func rejectsExpiredMetadata() {
        let snapshot = makeSnapshot(certificates: [makeCertificate()])
        let requirement = requirement(maximumMetadataAge: 60)

        #expect(snapshot.readiness(for: requirement, at: observedAt.addingTimeInterval(61)) ==
            .stale(.metadataExpired))
    }

    @Test("A certificate committed at another revision is superseded")
    func rejectsSupersededRevision() {
        let snapshot = makeSnapshot(
            revision: MirrorRevision(value: 8),
            certificates: [makeCertificate(revision: MirrorRevision(value: 9))]
        )

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .stale(.supersededRevision))
    }

    @Test("A preserved certificate remains admissible after a maintenance revision")
    func admitsPreservedCertificate() {
        let certificate = makeCertificate(revision: MirrorRevision(value: 8))
        let snapshot = makeSnapshot(revision: MirrorRevision(value: 9), certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .ready(certificate))
    }

    @Test("A different processing field set requires a fresh observation")
    func rejectsDifferentFieldSet() {
        let snapshot = makeSnapshot(certificates: [makeCertificate()])

        #expect(snapshot.readiness(
            for: MirrorRequirement(
                testArtists: ["Metallica"],
                fieldSet: MirrorFieldSet(version: 2),
                maximumMetadataAge: nil
            ),
            at: observedAt
        ) == .incomplete(.freshObservationRequired))
    }

    @Test("Certificate transitions preserve explicit intent")
    func preservesCertificateTransitionIntent() {
        let certificate = makeCertificate()
        let reason = InvalidationReason.narrowedObservation

        #expect(CertificateChange.preserve == .preserve)
        #expect(CertificateChange.replace(certificate) == .replace(certificate))
        #expect(CertificateChange.invalidate(reason) == .invalidate(reason))
        #expect(CertificateChange.rebase(certificate) == .rebase(certificate))
    }

    private func requirement(
        testArtists: [String] = ["  METALLICA  "],
        maximumMetadataAge: TimeInterval? = nil
    ) -> MirrorRequirement {
        MirrorRequirement(
            testArtists: testArtists,
            fieldSet: .processingV1,
            maximumMetadataAge: maximumMetadataAge
        )
    }

    private func makeSnapshot(
        revision: MirrorRevision = MirrorRevision(value: 8),
        certificates: [ScopeCertificate]
    ) -> TrackMirrorSnapshot {
        TrackMirrorSnapshot(
            revision: revision,
            membershipStamp: currentMembership,
            presentIDs: [],
            presentTracks: [],
            repairCandidates: [],
            certificates: certificates
        )
    }

    private func makeCertificate(
        revision: MirrorRevision = MirrorRevision(value: 8),
        membership: MembershipStamp? = nil,
        testArtists: [String] = ["Metallica"],
        requestedFingerprint: String = String(repeating: "c", count: 64),
        observedFingerprint: String = String(repeating: "c", count: 64)
    ) -> ScopeCertificate {
        ScopeCertificate(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)),
            revision: revision,
            membership: membership ?? currentMembership,
            testArtists: testArtists,
            fieldSet: .processingV1,
            requestedFingerprint: requestedFingerprint,
            observedFingerprint: observedFingerprint,
            trackCount: 1,
            observedAt: observedAt
        )
    }

    private func membership(repeating character: Character) -> MembershipStamp {
        do {
            return try MembershipStamp(fingerprint: String(repeating: character, count: 64))
        } catch {
            preconditionFailure("Invalid deterministic membership fixture: \(error.localizedDescription)")
        }
    }
}
