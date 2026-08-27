import Core
import Foundation
import SwiftData
import Testing
@testable import Services

@Suite("Scope certificate store")
struct ScopeCertificateStoreTests {
    enum InvalidReplacement: CaseIterable, Sendable {
        case revision
        case membership
        case fingerprints
        case trackCount
    }

    private struct ReplacementFixture {
        let certificate: ScopeCertificate
        let error: TrackStoreError
    }

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

    @Test("A maintenance-only preserve remains ready after relaunch")
    func preserveSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CertificatePreserve-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")
        let certificate: ScopeCertificate

        do {
            let store = try makeStore(at: storeURL)
            let membership = try MembershipFingerprint.make(ids: [testDatabaseID("A")])
            certificate = makeCertificate(revision: MirrorRevision(value: 1), membership: membership)
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
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: MirrorRevision(value: 1),
                observation: observationID(1),
                membershipChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve
            ))
        }

        let snapshot = try await makeStore(at: storeURL).loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.readiness(
            for: MirrorRequirement(testArtists: [], fieldSet: .processingV1, maximumMetadataAge: nil),
            at: certificate.observedAt
        ) == .ready(certificate))
    }

    @Test("A mutating commit invalidates the certificate across relaunch")
    func invalidatesMutationOnRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CertificateInvalidate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let store = try makeStore(at: storeURL)
            let membership = try MembershipFingerprint.make(ids: [testDatabaseID("A")])
            let certificate = makeCertificate(revision: MirrorRevision(value: 1), membership: membership)
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                observation: observationID(0),
                membershipChange: .replace(
                    stamp: membership,
                    ids: [testDatabaseID("A")],
                    observedAt: observedAt
                ),
                repairs: [],
                upserts: [certificateTrack(id: "A")],
                certificates: .replace(certificate)
            ))
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: MirrorRevision(value: 1),
                observation: observationID(1),
                membershipChange: .preserve,
                repairs: [],
                upserts: [certificateTrack(id: "A", genre: "Metal")],
                certificates: .invalidate(.incompleteObservation)
            ))
        }

        let snapshot = try await makeStore(at: storeURL).loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.certificates.isEmpty)
        #expect(snapshot.readiness(
            for: MirrorRequirement(testArtists: [], fieldSet: .processingV1, maximumMetadataAge: nil),
            at: observedAt
        ) == .incomplete(.freshObservationRequired))
    }

    @Test("Preserve rejects processing metadata mutations")
    func preserveRejectsUpserts() async throws {
        let fixture = try await seededStore()

        await #expect(throws: TrackStoreError.unsafeCertificatePreserve) {
            try await fixture.store.commitMirror(MirrorCommit(
                baseRevision: MirrorRevision(value: 1),
                observation: observationID(2),
                membershipChange: .preserve,
                repairs: [],
                upserts: [certificateTrack(id: "A", genre: "Metal")],
                certificates: .preserve
            ))
        }

        let snapshot = try await fixture.store.loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 1))
        #expect(snapshot.certificates == [fixture.certificate])
    }

    @Test("Preserve rejects canonical membership transitions")
    func preserveRejectsMembershipChanges() async throws {
        let fixture = try await seededStore()

        await #expect(throws: TrackStoreError.unsafeCertificatePreserve) {
            try await fixture.store.commitMirror(MirrorCommit(
                baseRevision: MirrorRevision(value: 1),
                observation: observationID(3),
                membershipChange: .replace(
                    stamp: fixture.membership,
                    ids: [testDatabaseID("A")],
                    observedAt: fixture.certificate.observedAt
                ),
                repairs: [],
                upserts: [],
                certificates: .preserve
            ))
        }

        #expect(try await fixture.store.loadMirrorSnapshot().revision == MirrorRevision(value: 1))
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

    @Test("Rebase fails closed without disjoint membership proof")
    func rejectsUnprovenRebase() async throws {
        let fixture = try await seededStore()
        let rebased = makeCertificate(revision: MirrorRevision(value: 2), membership: fixture.membership)

        await #expect(throws: TrackStoreError.unprovenCertificateRebase) {
            try await fixture.store.commitMirror(MirrorCommit(
                baseRevision: MirrorRevision(value: 1),
                observation: observationID(4),
                membershipChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .rebase(rebased)
            ))
        }

        let snapshot = try await fixture.store.loadMirrorSnapshot()
        #expect(snapshot.revision == MirrorRevision(value: 1))
        #expect(snapshot.certificates == [fixture.certificate])
    }

    @Test(
        "Invalid replacement certificates leave the persisted mirror unchanged",
        arguments: InvalidReplacement.allCases
    )
    func rejectsInvalidReplacement(_ invalid: InvalidReplacement) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "InvalidCertificate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "GenreUpdater.store")
        let membership = try MembershipFingerprint.make(ids: [testDatabaseID("A")])
        let otherMembership = try MembershipFingerprint.make(ids: [testDatabaseID("B")])
        let original = makeCertificate(revision: MirrorRevision(value: 1), membership: membership)
        let invalidFixture = makeInvalidFixture(invalid, membership: membership, other: otherMembership)

        let expectedSnapshot: TrackMirrorSnapshot
        do {
            let store = try makeStore(at: storeURL)
            _ = try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                observation: observationID(0),
                membershipChange: .replace(
                    stamp: membership,
                    ids: [testDatabaseID("A")],
                    observedAt: original.observedAt
                ),
                repairs: [],
                upserts: [certificateTrack(id: "A")],
                certificates: .replace(original)
            ))
            expectedSnapshot = try await store.loadMirrorSnapshot()

            do {
                _ = try await store.commitMirror(MirrorCommit(
                    baseRevision: MirrorRevision(value: 1),
                    observation: observationID(1),
                    membershipChange: .preserve,
                    repairs: [],
                    upserts: [],
                    certificates: .replace(invalidFixture.certificate)
                ))
                Issue.record("Expected the invalid replacement certificate to be rejected")
            } catch let error as TrackStoreError {
                #expect(error == invalidFixture.error)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            #expect(try await store.loadMirrorSnapshot() == expectedSnapshot)
            #expect(try await store.trackCount() == 1)
        }

        let reopened = try makeStore(at: storeURL)
        #expect(try await reopened.loadMirrorSnapshot() == expectedSnapshot)
        #expect(try await reopened.trackCount() == 1)
    }

    private func makeInvalidFixture(
        _ invalid: InvalidReplacement,
        membership: MembershipStamp,
        other: MembershipStamp
    ) -> ReplacementFixture {
        switch invalid {
        case .revision:
            ReplacementFixture(
                certificate: makeCertificate(revision: MirrorRevision(value: 1), membership: membership),
                error: .certificateRevisionMismatch(
                    expected: MirrorRevision(value: 2),
                    actual: MirrorRevision(value: 1)
                )
            )
        case .membership:
            ReplacementFixture(
                certificate: makeCertificate(revision: MirrorRevision(value: 2), membership: other),
                error: .certificateMembershipMismatch(expected: membership, actual: other)
            )
        case .fingerprints:
            ReplacementFixture(
                certificate: makeCertificate(
                    revision: MirrorRevision(value: 2),
                    membership: membership,
                    requestedFingerprint: membership.fingerprint,
                    observedFingerprint: other.fingerprint
                ),
                error: .incompleteCertificate
            )
        case .trackCount:
            ReplacementFixture(
                certificate: makeCertificate(
                    revision: MirrorRevision(value: 2),
                    membership: membership,
                    trackCount: -1
                ),
                error: .invalidCertificateTrackCount(-1)
            )
        }
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
        membership: MembershipStamp,
        requestedFingerprint: String? = nil,
        observedFingerprint: String? = nil,
        trackCount: Int = 1
    ) -> ScopeCertificate {
        ScopeCertificate(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)),
            revision: revision,
            membership: membership,
            testArtists: [],
            fieldSet: .processingV1,
            requestedFingerprint: requestedFingerprint ?? membership.fingerprint,
            observedFingerprint: observedFingerprint ?? membership.fingerprint,
            trackCount: trackCount,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func observationID(_ suffix: UInt8) -> ObservationID {
        ObservationID(value: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix)))
    }

    private func makeStore(at storeURL: URL) throws -> TrackDataStore {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "GenreUpdater",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try TrackDataStore(modelContainer: ModelContainerFactory.create(
            schema: schema,
            configuration: configuration
        ))
    }

    private func certificateTrack(id: String, genre: String? = nil) -> Track {
        Track(id: id, name: "Song", artist: "Artist", album: "Album", genre: genre, appleScriptID: id)
    }
}
