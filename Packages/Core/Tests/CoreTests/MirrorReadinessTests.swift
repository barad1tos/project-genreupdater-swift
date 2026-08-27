import Foundation
import Testing
@testable import Core

@Suite("Mirror readiness certificates")
struct MirrorReadinessTests {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private var currentMembership: MembershipStamp {
        membership(ids: [databaseID("A")])
    }

    private var previousMembership: MembershipStamp {
        membership(ids: [databaseID("B")])
    }

    @Test("An exact current certificate admits its processing requirement")
    func admitsExactCertificate() {
        let certificate = makeCertificate()
        let snapshot = makeSnapshot(certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .ready(certificate))
    }

    @Test("Certificate coding preserves flat persisted evidence fields")
    func preservesFlatWire() throws {
        let certificate = makeCertificate()
        let encoded = try JSONEncoder().encode(certificate)
        let flatEvidence = try JSONDecoder().decode(FlatScopeEvidence.self, from: encoded)
        let decoded = try JSONDecoder().decode(ScopeCertificate.self, from: encoded)

        #expect(flatEvidence.requestedFingerprint == currentMembership.fingerprint)
        #expect(flatEvidence.observedFingerprint == currentMembership.fingerprint)
        #expect(flatEvidence.trackCount == 1)
        #expect(makeSnapshot(certificates: [decoded]).readiness(for: requirement(), at: observedAt) == .ready(decoded))
    }

    @Test("A scoped certificate measures only canonical rows in its exact artist scope")
    func admitsExactScopedRows() {
        let metallicaID = databaseID("A")
        let bjorkID = databaseID("B")
        let presentIDs = Set([metallicaID, bjorkID])
        let certificate = makeCertificate(
            membershipStamp: membership(ids: Array(presentIDs)),
            trackIDs: [metallicaID]
        )
        let snapshot = makeSnapshot(
            presentIDs: presentIDs,
            tracks: [
                track(id: "A", artist: "Metallica"),
                track(id: "B", artist: "Björk"),
            ],
            certificates: [certificate]
        )

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .ready(certificate))
    }

    @Test("Scoped readiness does not require physical rows for unrelated census members")
    func admitsPartialScope() {
        let targetID = databaseID("A")
        let outsideID = databaseID("B")
        let presentIDs = Set([targetID, outsideID])
        let certificate = makeCertificate(
            membershipStamp: membership(ids: Array(presentIDs)),
            trackIDs: [targetID]
        )
        let snapshot = makeSnapshot(
            presentIDs: presentIDs,
            tracks: [track(id: "A", artist: "Metallica")],
            certificates: [certificate]
        )

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .ready(certificate))
    }

    @Test("A missing scoped canonical row remains fail-closed")
    func rejectsMissingScopedRow() {
        let targetID = databaseID("A")
        let outsideID = databaseID("B")
        let presentIDs = Set([targetID, outsideID])
        let certificate = makeCertificate(
            membershipStamp: membership(ids: Array(presentIDs)),
            trackIDs: [targetID]
        )
        let snapshot = makeSnapshot(
            presentIDs: presentIDs,
            tracks: [track(id: "B", artist: "Other")],
            certificates: [certificate]
        )

        #expect(snapshot.readiness(for: requirement(), at: observedAt) ==
            .incomplete(.metadataMissing(count: 1)))
    }

    @Test("A missing canonical row fails closed before certificate admission")
    func rejectsPartialPhysicalMirror() {
        let firstID = databaseID("A")
        let missingID = databaseID("B")
        let presentIDs = Set([firstID, missingID])
        let certificate = makeCertificate(
            membershipStamp: membership(ids: Array(presentIDs)),
            testArtists: [],
            trackIDs: [firstID, missingID]
        )
        let snapshot = makeSnapshot(
            presentIDs: presentIDs,
            tracks: [track(id: "A", artist: "Metallica")],
            certificates: [certificate]
        )

        #expect(snapshot.readiness(for: requirement(testArtists: []), at: observedAt) ==
            .incomplete(.identityMissing(count: 1)))
    }

    @Test("A certificate count must match its canonical scoped rows")
    func rejectsWrongTrackCount() {
        let certificate = makeCertificate(evidence: ScopeEvidence(
            requestedFingerprint: currentMembership.fingerprint,
            observedFingerprint: currentMembership.fingerprint,
            trackCount: 2
        ))
        let snapshot = makeSnapshot(certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .incomplete(.metadataMissing(count: 1)))
    }

    @Test("A certificate fingerprint must match its canonical scoped rows")
    func rejectsWrongFingerprint() {
        let wrongFingerprint = membership(ids: [databaseID("B")]).fingerprint
        let certificate = makeCertificate(evidence: ScopeEvidence(
            requestedFingerprint: wrongFingerprint,
            observedFingerprint: wrongFingerprint,
            trackCount: 1
        ))
        let snapshot = makeSnapshot(certificates: [certificate])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .incomplete(.metadataMissing(count: 1)))
    }

    @Test("A certificate from another membership is stale")
    func rejectsChangedMembership() {
        let certificate = makeCertificate(membershipStamp: previousMembership)
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
        let certificate = makeCertificate(evidence: ScopeEvidence(
            requestedFingerprint: String(repeating: "c", count: 64),
            observedFingerprint: String(repeating: "d", count: 64),
            trackCount: 1
        ))
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

    @Test("A certificate expires at the exact freshness boundary")
    func expiresAtBoundary() {
        let snapshot = makeSnapshot(certificates: [makeCertificate()])
        let requirement = requirement(maximumMetadataAge: 60)

        #expect(snapshot.readiness(for: requirement, at: observedAt.addingTimeInterval(60)) ==
            .stale(.metadataExpired))
    }

    @Test(
        "Invalid maximum metadata ages fail closed",
        arguments: [TimeInterval.nan, .infinity, -.infinity, -1]
    )
    func rejectsInvalidAge(_ maximumMetadataAge: TimeInterval) {
        let snapshot = makeSnapshot(certificates: [makeCertificate()])

        #expect(snapshot.readiness(
            for: requirement(maximumMetadataAge: maximumMetadataAge),
            at: observedAt
        ) == .unavailable(MirrorFailure(
            category: .storage,
            detail: "Maximum metadata age must be finite and non-negative"
        )))
    }

    @Test("A future observation timestamp fails closed")
    func rejectsFutureObservation() {
        let snapshot = makeSnapshot(certificates: [makeCertificate()])

        #expect(snapshot.readiness(for: requirement(), at: observedAt.addingTimeInterval(-1)) ==
            .unavailable(MirrorFailure(
                category: .storage,
                detail: "Mirror observation timestamp is in the future"
            )))
    }

    @Test(
        "Non-finite observation ages fail closed",
        arguments: [TimeInterval.nan, .infinity, -.infinity]
    )
    func rejectsNonFiniteAge(_ observationTime: TimeInterval) {
        let snapshot = makeSnapshot(certificates: [makeCertificate(
            observedAt: Date(timeIntervalSince1970: observationTime)
        )])

        #expect(snapshot.readiness(for: requirement(), at: observedAt) ==
            .unavailable(MirrorFailure(
                category: .storage,
                detail: "Mirror observation age must be finite"
            )))
    }

    @Test("Album artist admits a track when its primary artist is outside the scope")
    func admitsMatchingAlbumArtist() {
        let snapshot = makeSnapshot(
            tracks: [track(id: "A", artist: "Other", albumArtist: "Metallica")],
            certificates: [makeCertificate()]
        )

        #expect(snapshot.readiness(for: requirement(), at: observedAt) == .ready(makeCertificate()))
    }

    @Test("Album artist excludes a track even when its primary artist matches the scope")
    func rejectsNonmatchingAlbumArtist() {
        let snapshot = makeSnapshot(
            tracks: [track(id: "A", artist: "Metallica", albumArtist: "Other")],
            certificates: [makeCertificate()]
        )

        #expect(snapshot.readiness(for: requirement(), at: observedAt) ==
            .incomplete(.metadataMissing(count: 1)))
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
        presentIDs: Set<MusicDatabaseTrackID>? = nil,
        tracks: [Track]? = nil,
        certificates: [ScopeCertificate]
    ) -> TrackMirrorSnapshot {
        let resolvedTracks = tracks ?? [track(id: "A", artist: "Metallica")]
        let resolvedIDs = presentIDs ?? Set(resolvedTracks.compactMap(\.databaseID))
        return TrackMirrorSnapshot(
            revision: revision,
            membershipStamp: membership(ids: Array(resolvedIDs)),
            presentIDs: resolvedIDs,
            presentTracks: resolvedTracks,
            repairCandidates: [],
            certificates: certificates
        )
    }

    private func makeCertificate(
        revision: MirrorRevision = MirrorRevision(value: 8),
        membershipStamp: MembershipStamp? = nil,
        testArtists: [String] = ["Metallica"],
        trackIDs: [MusicDatabaseTrackID]? = nil,
        evidence: ScopeEvidence? = nil,
        observedAt: Date? = nil
    ) -> ScopeCertificate {
        let resolvedTrackIDs = trackIDs ?? [databaseID("A")]
        let fingerprint = membership(ids: resolvedTrackIDs).fingerprint
        return ScopeCertificate(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8)),
            revision: revision,
            membership: membershipStamp ?? currentMembership,
            testArtists: testArtists,
            fieldSet: .processingV1,
            evidence: evidence ?? ScopeEvidence(
                requestedFingerprint: fingerprint,
                observedFingerprint: fingerprint,
                trackCount: resolvedTrackIDs.count
            ),
            observedAt: observedAt ?? self.observedAt
        )
    }

    private func track(id: String, artist: String, albumArtist: String? = nil) -> Track {
        Track(
            id: id,
            name: "Song",
            artist: artist,
            album: "Album",
            albumArtist: albumArtist,
            appleScriptID: id
        )
    }

    private func databaseID(_ value: String) -> MusicDatabaseTrackID {
        guard let databaseID = MusicDatabaseTrackID(rawValue: value) else {
            preconditionFailure("Invalid deterministic database ID fixture")
        }
        return databaseID
    }

    private func membership(ids: [MusicDatabaseTrackID]) -> MembershipStamp {
        do {
            return try MembershipFingerprint.make(ids: ids)
        } catch {
            preconditionFailure("Invalid deterministic membership fixture: \(error.localizedDescription)")
        }
    }
}

private struct FlatScopeEvidence: Decodable {
    let requestedFingerprint: String
    let observedFingerprint: String
    let trackCount: Int
}
