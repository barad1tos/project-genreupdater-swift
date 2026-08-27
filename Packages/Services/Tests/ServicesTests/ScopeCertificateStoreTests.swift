import Core
import Foundation
import Testing
@testable import Services

@Suite("Scope certificate store")
struct ScopeCertificateStoreTests {
    @Test("Replace persists one certificate with membership and track changes")
    func replacesCertificateAtomically() async throws {
        let store = try TrackDataStore.createInMemory()
        let track = certificateTrack(id: "A")
        let membership = try MembershipFingerprint.make(ids: [testDatabaseID("A")])
        let certificate = makeCertificate(revision: MirrorRevision(value: 1), membership: membership)

        let result = try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            observation: observationID(1),
            membershipChange: .replace(
                stamp: membership,
                ids: [testDatabaseID("A")],
                observedAt: certificate.observedAt
            ),
            repairs: [],
            upserts: [track],
            certificates: .replace(certificate)
        ))

        let snapshot = try await store.loadMirrorSnapshot()
        #expect(result.revision == MirrorRevision(value: 1))
        #expect(snapshot.presentIDs == [testDatabaseID("A")])
        #expect(snapshot.presentTracks.map(\.id) == ["A"])
        #expect(snapshot.certificates == [certificate])
    }

    @Test("Preserve leaves the current certificate unchanged")
    func preservesCertificate() async throws {
        let fixture = try await seededStore()

        _ = try await fixture.store.commitMirror(MirrorCommit(
            baseRevision: MirrorRevision(value: 1),
            observation: observationID(2),
            membershipChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve
        ))

        let snapshot = try await fixture.store.loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.certificates == [fixture.certificate])
    }

    @Test("Invalidate removes every admissible certificate")
    func invalidatesCertificate() async throws {
        let fixture = try await seededStore()

        _ = try await fixture.store.commitMirror(MirrorCommit(
            baseRevision: MirrorRevision(value: 1),
            observation: observationID(3),
            membershipChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .invalidate(.narrowedObservation)
        ))

        #expect(try await fixture.store.loadMirrorSnapshot().certificates.isEmpty)
    }

    @Test("A proven rebase replaces the prior certificate")
    func rebasesCertificate() async throws {
        let fixture = try await seededStore()
        let rebased = makeCertificate(revision: MirrorRevision(value: 2), membership: fixture.membership)

        _ = try await fixture.store.commitMirror(MirrorCommit(
            baseRevision: MirrorRevision(value: 1),
            observation: observationID(4),
            membershipChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .rebase(rebased)
        ))

        #expect(try await fixture.store.loadMirrorSnapshot().certificates == [rebased])
    }

    private func seededStore() async throws -> (
        store: TrackDataStore,
        membership: MembershipStamp,
        certificate: ScopeCertificate
    ) {
        let store = try TrackDataStore.createInMemory()
        let membership = try MembershipFingerprint.make(ids: [testDatabaseID("A")])
        let certificate = makeCertificate(revision: MirrorRevision(value: 1), membership: membership)
        _ = try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            observation: observationID(0),
            membershipChange: .replace(
                stamp: membership,
                ids: [testDatabaseID("A")],
                observedAt: certificate.observedAt
            ),
            repairs: [],
            upserts: [certificateTrack(id: "A")],
            certificates: .replace(certificate)
        ))
        return (store, membership, certificate)
    }

    private func makeCertificate(
        revision: MirrorRevision,
        membership: MembershipStamp
    ) -> ScopeCertificate {
        ScopeCertificate(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)),
            revision: revision,
            membership: membership,
            testArtists: [],
            fieldSet: .processingV1,
            requestedFingerprint: membership.fingerprint,
            observedFingerprint: membership.fingerprint,
            trackCount: 1,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func observationID(_ suffix: UInt8) -> ObservationID {
        ObservationID(value: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)))
    }

    private func certificateTrack(id: String) -> Track {
        Track(id: id, name: "Song", artist: "Artist", album: "Album", appleScriptID: id)
    }
}
