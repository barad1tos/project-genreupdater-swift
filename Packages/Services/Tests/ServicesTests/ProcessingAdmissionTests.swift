import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Processing admission")
struct ProcessingAdmissionTests {
    @Test("Admission preserves the requested scope and exact certificate")
    func admissionPreservesScopeAndCertificate() async throws {
        let fixture = try AdmissionFixture()

        let decision = try await fixture.store.admit(
            scope: fixture.scope,
            requirement: fixture.requirement,
            at: fixture.decisionDate
        )

        let expectedAdmission = ProcessingAdmission(
            scopeID: fixture.scope.id,
            certificate: fixture.certificate,
            maximumMetadataAge: fixture.requirement.maximumMetadataAge
        )
        #expect(decision == .admitted(expectedAdmission, tracks: fixture.tracks))
        #expect(await fixture.store.snapshotLoadCount == 1)
    }

    @Test("Admission rejects a requested scope that does not match its requirement")
    func admissionRejectsScopeMismatch() async throws {
        let fixture = try AdmissionFixture()
        let mismatchedRequirement = MirrorRequirement(
            testArtists: ["Boards of Canada"],
            fieldSet: .processingV1,
            maximumMetadataAge: fixture.requirement.maximumMetadataAge
        )

        let decision = try await fixture.store.admit(
            scope: fixture.scope,
            requirement: mismatchedRequirement,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.scopeMismatch))
    }

    @Test("Revalidation rejects an admission when the current certificate changed")
    func revalidationRejectsChangedCertificate() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        let replacement = try fixture.certificate(id: UUID())
        try await fixture.store.replaceSnapshot(fixture.snapshot(certificate: replacement))

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: fixture.tracks,
            match: .exactScope,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.certificateChanged))
        #expect(await fixture.store.snapshotLoadCount == 2)
    }

    @Test("Revalidation requires the current mirror to admit the captured requirement")
    func revalidationRequiresCurrentMirrorAdmission() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        try await fixture.store.replaceSnapshot(fixture.snapshot(certificates: []))

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: fixture.tracks,
            match: .exactScope,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.mirror(.incomplete(.freshObservationRequired))))
    }

    @Test("Mirror rejection takes precedence over a noncanonical candidate")
    func mirrorRejectionPrecedesCandidateValidation() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        try await fixture.store.replaceSnapshot(fixture.snapshot(certificates: []))

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: [nonCanonicalTrack()],
            match: .subset,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.mirror(.incomplete(.freshObservationRequired))))
    }

    @Test("Certificate change takes precedence over an invalid candidate")
    func certificateChangePrecedesCandidateValidation() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        let replacement = try fixture.certificate(id: UUID())
        try await fixture.store.replaceSnapshot(fixture.snapshot(certificate: replacement))

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: [nonCanonicalTrack()],
            match: .subset,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.certificateChanged))
    }

    @Test("Exact-scope revalidation rejects a proper subset")
    func exactScopeRejectsSubset() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: [fixture.tracks[0]],
            match: .exactScope,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.trackSetMismatch))
    }

    @Test("Exact-scope revalidation accepts every certified row")
    func exactScopeAcceptsCertifiedRows() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: fixture.tracks,
            match: .exactScope,
            at: fixture.decisionDate
        )

        #expect(decision == .admitted(admission, tracks: fixture.tracks))
    }

    @Test("Subset revalidation preserves the validated candidate rows")
    func subsetAcceptsCandidateRows() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        let candidates = [fixture.tracks[1]]

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: candidates,
            match: .subset,
            at: fixture.decisionDate
        )

        #expect(decision == .admitted(admission, tracks: candidates))
    }

    @Test("Subset revalidation rejects canonical tracks outside the admitted scope")
    func subsetRejectsOutsideScopeTrack() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        let outsideTrack = canonicalTrack(id: "outside", artist: "Aphex Twin")

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: [outsideTrack],
            match: .subset,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.trackSetMismatch))
    }

    @Test("Revalidation rejects duplicate Music database IDs")
    func revalidationRejectsDuplicateDatabaseIDs() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        let duplicateID = fixture.tracks[0].databaseID

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: [fixture.tracks[0], fixture.tracks[0]],
            match: .subset,
            at: fixture.decisionDate
        )

        #expect(try decision == .rejected(.duplicateTrack(#require(duplicateID))))
    }

    @Test("Revalidation rejects noncanonical candidate identities")
    func revalidationRejectsNonCanonicalTrack() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()

        let decision = try await fixture.store.revalidate(
            admission,
            candidates: [nonCanonicalTrack()],
            match: .subset,
            at: fixture.decisionDate
        )

        #expect(decision == .rejected(.nonCanonicalTrack("legacy-read-id")))
    }

    @Test("Admission propagates mirror storage errors")
    func admissionPropagatesStorageError() async throws {
        let fixture = try AdmissionFixture()
        await fixture.store.failSnapshotLoads()

        await #expect(throws: AdmissionStoreError.storage) {
            try await fixture.store.admit(
                scope: fixture.scope,
                requirement: fixture.requirement,
                at: fixture.decisionDate
            )
        }
    }

    @Test("Revalidation propagates mirror storage errors")
    func revalidationPropagatesStorageError() async throws {
        let fixture = try AdmissionFixture()
        let admission = try await fixture.admission()
        await fixture.store.failSnapshotLoads()

        await #expect(throws: AdmissionStoreError.storage) {
            try await fixture.store.revalidate(
                admission,
                candidates: fixture.tracks,
                match: .exactScope,
                at: fixture.decisionDate
            )
        }
    }

    @Test("Every rejection explains how to recover")
    func rejectionExplainsRecovery() throws {
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "track-a"))
        let cases: [(ProcessingAdmissionRejection, String)] = [
            (
                .mirror(.stale(.membershipChanged)),
                "The Music library changed before processing. Scan the library again."
            ),
            (
                .mirror(.incomplete(.metadataMissing(count: 2))),
                "The library mirror is missing required metadata for 2 tracks. Scan the library again."
            ),
            (
                .mirror(.unavailable(MirrorFailure(category: .storage, detail: "database unavailable"))),
                "The library mirror is unavailable (storage): database unavailable. Try the scan again."
            ),
            (
                .scopeMismatch,
                "The requested processing scope does not match its library evidence. Start the run again."
            ),
            (
                .certificateChanged,
                "The library evidence changed before processing. Scan the library again."
            ),
            (
                .nonCanonicalTrack("legacy-read-id"),
                "Track legacy-read-id lacks canonical Music database identity. "
                    + "Repair the library mirror and scan again."
            ),
            (
                .duplicateTrack(databaseID),
                "Track track-a appears more than once in the processing set. Repair the library mirror and scan again."
            ),
            (
                .trackSetMismatch,
                "The processing tracks no longer match the certified library scope. Scan the library again."
            ),
        ]

        for (rejection, expectedDescription) in cases {
            #expect(rejection.localizedDescription == expectedDescription)
        }
    }
}

private struct AdmissionFixture {
    let tracks: [Track]
    let certificate: ScopeCertificate
    let scope: ProcessingScopeSnapshot
    let requirement: MirrorRequirement
    let decisionDate = Date(timeIntervalSince1970: 1_700_000_100)
    let store: AdmissionTrackStore

    init() throws {
        tracks = [
            canonicalTrack(id: "track-a", artist: "Aphex Twin"),
            canonicalTrack(id: "track-b", artist: "Aphex Twin"),
        ]
        requirement = MirrorRequirement(
            testArtists: ["Aphex Twin"],
            fieldSet: .processingV1,
            maximumMetadataAge: 1000
        )
        scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Aphex Twin"],
            knownTrackCount: tracks.count,
            createdAt: Date(timeIntervalSince1970: 1_700_000_050),
            reason: "admission-test"
        )
        certificate = try Self.makeCertificate(tracks: tracks)
        store = try AdmissionTrackStore(snapshot: Self.makeSnapshot(
            tracks: tracks,
            certificates: [certificate]
        ))
    }

    func admission() async throws -> ProcessingAdmission {
        let decision = try await store.admit(scope: scope, requirement: requirement, at: decisionDate)
        guard case let .admitted(admission, _) = decision else {
            Issue.record("Expected fixture mirror to admit processing")
            throw AdmissionStoreError.fixtureRejected
        }
        return admission
    }

    func certificate(id: UUID) throws -> ScopeCertificate {
        try Self.makeCertificate(id: id, tracks: tracks)
    }

    func snapshot(certificate: ScopeCertificate) throws -> TrackMirrorSnapshot {
        try snapshot(certificates: [certificate])
    }

    func snapshot(certificates: [ScopeCertificate]) throws -> TrackMirrorSnapshot {
        try Self.makeSnapshot(tracks: tracks, certificates: certificates)
    }

    private static func makeCertificate(
        id: UUID = UUID(),
        tracks: [Track]
    ) throws -> ScopeCertificate {
        let trackIDs = tracks.compactMap(\.databaseID)
        let membership = try MembershipFingerprint.make(ids: trackIDs)
        let fingerprint = try MembershipFingerprint.make(ids: trackIDs).fingerprint
        return ScopeCertificate(
            id: id,
            revision: MirrorRevision(value: 1),
            membership: membership,
            testArtists: ["Aphex Twin"],
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: fingerprint,
                observedFingerprint: fingerprint,
                trackCount: trackIDs.count
            ),
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func makeSnapshot(
        tracks: [Track],
        certificates: [ScopeCertificate]
    ) throws -> TrackMirrorSnapshot {
        let trackIDs = Set(tracks.compactMap(\.databaseID))
        let identities = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            track.databaseID.map { databaseID in
                (databaseID, MemberIdentity(
                    databaseID: databaseID,
                    artist: track.artist,
                    albumArtist: track.albumArtist,
                    observedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ))
            }
        })
        return try TrackMirrorSnapshot(
            revision: MirrorRevision(value: 1),
            membershipStamp: MembershipFingerprint.make(ids: Array(trackIDs)),
            presentIDs: trackIDs,
            memberIdentities: identities,
            presentTracks: tracks,
            repairCandidates: [],
            certificates: certificates
        )
    }
}

private actor AdmissionTrackStore: TrackStateStore {
    private var snapshot: TrackMirrorSnapshot
    private var shouldFailSnapshotLoads = false
    private(set) var snapshotLoadCount = 0

    init(snapshot: TrackMirrorSnapshot) {
        self.snapshot = snapshot
    }

    func replaceSnapshot(_ snapshot: TrackMirrorSnapshot) {
        self.snapshot = snapshot
    }

    func failSnapshotLoads() {
        shouldFailSnapshotLoads = true
    }

    func initialize() async throws {
        // The fixture receives its complete in-memory snapshot at construction.
    }

    func loadAllTracks() async throws -> [Track] {
        snapshot.presentTracks
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        snapshotLoadCount += 1
        if shouldFailSnapshotLoads {
            throw AdmissionStoreError.storage
        }
        return snapshot
    }

    func commitMirror(_: MirrorCommit) async throws -> MirrorCommitResult {
        throw AdmissionStoreError.unusedOperation
    }

    func getTrack(byID id: String) async throws -> Track? {
        snapshot.presentTracks.first { $0.id == id }
    }

    func persistAppliedChange(_: ChangeLogEntry) async throws {
        throw AdmissionStoreError.unusedOperation
    }

    func getUnprocessedTracks() async throws -> [Track] {
        snapshot.presentTracks
    }

    func trackCount() async throws -> Int {
        snapshot.presentTracks.count
    }
}

private enum AdmissionStoreError: Error, Equatable {
    case fixtureRejected
    case storage
    case unusedOperation
}

private func canonicalTrack(id: String, artist: String) -> Track {
    Track(
        id: id,
        name: "Xtal",
        artist: artist,
        album: "Selected Ambient Works 85-92",
        appleScriptID: id
    )
}

private func nonCanonicalTrack() -> Track {
    Track(
        id: "legacy-read-id",
        name: "Xtal",
        artist: "Aphex Twin",
        album: "Selected Ambient Works 85-92",
        appleScriptID: "database-id"
    )
}
