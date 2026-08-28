import Core
import Foundation
import Testing
@testable import Services

@Suite("Library sync observation validation")
struct LibrarySyncValidationTests {
    @Test("Validation rejects a scoped result that omits a matching identity")
    func rejectsForgedScopeClassification() async throws {
        let service = makeService()
        let request = identityRequest()
        let databaseID = testDatabaseID("A")
        let observation = try identityObservation(
            request: request,
            identity: LibraryIdentityRow(
                databaseID: databaseID,
                artist: .value("Target"),
                albumArtist: .absent
            ),
            currentIDs: []
        )

        await #expect(throws: LibrarySyncObservationError.invalidObservation(
            detail: "current scope does not match identity classification"
        )) {
            try await service.validate(observation, request: request)
        }
    }

    @Test("Validation rejects unobserved identity fields")
    func rejectsIncompleteIdentityRow() async throws {
        let service = makeService()
        let request = identityRequest()
        let databaseID = testDatabaseID("A")
        let observation = try identityObservation(
            request: request,
            identity: LibraryIdentityRow(
                databaseID: databaseID,
                artist: .unobserved(reason: "omitted"),
                albumArtist: .absent
            ),
            currentIDs: []
        )

        await #expect(throws: LibrarySyncObservationError.invalidObservation(
            detail: "identity rows contain unobserved fields"
        )) {
            try await service.validate(observation, request: request)
        }
    }

    @Test("Force validation requires current identity coverage")
    func rejectsForceWithoutIdentityCoverage() async throws {
        let databaseID = testDatabaseID("A")
        let identity = MemberIdentity(
            databaseID: databaseID,
            artist: "Target",
            albumArtist: nil,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let inventory = try #require(LibraryInventoryIndex(identitiesByID: [databaseID: identity]))
        let request = LibraryObservationRequest(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Target"],
                knownTrackCount: 1,
                createdAt: identity.observedAt,
                reason: "force-validation"
            ),
            refresh: .force,
            previous: .initial,
            inventory: inventory
        )
        let observation = try LibraryObservation(
            tracks: [metadataRow(databaseID: databaseID)],
            identities: [],
            epoch: LibraryObservationEpoch(
                censusIDs: [databaseID],
                currentIDs: [databaseID],
                scope: request.scope,
                observedAt: identity.observedAt,
                generation: #require(LibraryGeneration(sourceValue: "G1"))
            ),
            coverage: LibraryObservationCoverage(
                membership: .scoped(unobservedIDs: []),
                identity: IdentityCompleteness(requestedIDs: [], observedIDs: []),
                metadata: MetadataCompleteness(requestedIDs: [databaseID], observedIDs: [databaseID]),
                issues: []
            )
        )

        await #expect(throws: LibrarySyncObservationError.invalidObservation(
            detail: "identity coverage does not match its request"
        )) {
            try await makeService().validate(observation, request: request)
        }
    }

    private func makeService() -> LibrarySyncService {
        LibrarySyncService(
            trackStore: ObservationMirrorStore(stored: []),
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Target"]),
            observer: ObservationReader()
        )
    }

    private func identityRequest() -> LibraryObservationRequest {
        LibraryObservationRequest(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Target"],
                knownTrackCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                reason: "identity-validation"
            ),
            refresh: .force,
            previous: .initial
        )
    }

    private func identityObservation(
        request: LibraryObservationRequest,
        identity: LibraryIdentityRow,
        currentIDs: Set<MusicDatabaseTrackID>
    ) throws -> LibraryObservation {
        try LibraryObservation(
            tracks: [],
            identities: [identity],
            epoch: LibraryObservationEpoch(
                censusIDs: [identity.databaseID],
                currentIDs: currentIDs,
                scope: request.scope,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                generation: #require(LibraryGeneration(sourceValue: "G1"))
            ),
            coverage: LibraryObservationCoverage(
                membership: .scoped(unobservedIDs: []),
                identity: IdentityCompleteness(
                    requestedIDs: [identity.databaseID],
                    observedIDs: [identity.databaseID]
                ),
                metadata: MetadataCompleteness(requestedIDs: [], observedIDs: []),
                issues: []
            )
        )
    }

    private func metadataRow(databaseID: MusicDatabaseTrackID) -> LibraryTrackRow {
        LibraryTrackRow(
            databaseID: databaseID,
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: .value("Track"),
                    artist: .value("Target"),
                    album: .value("Album"),
                    albumArtist: .absent
                ),
                genre: .absent,
                editableYear: .absent,
                releaseYear: .absent,
                dateAdded: .absent,
                lastModified: .absent,
                status: .absent
            )
        )
    }
}
