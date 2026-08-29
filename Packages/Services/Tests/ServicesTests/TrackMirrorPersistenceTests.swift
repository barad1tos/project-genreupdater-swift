import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Track mirror persistence")
struct TrackMirrorPersistenceTests {
    private func track(id: String, name: String? = nil) -> Track {
        Track(
            id: id,
            name: name ?? id,
            artist: "Artist",
            album: "Album",
            appleScriptID: id
        )
    }

    private func databaseID(_ value: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: value))
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = ModelContainerFactory.makeSchema()
        let configuration = ModelConfiguration(
            "TrackMirrorRelaunch",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.create(schema: schema, configuration: configuration)
    }

    @Test("An empty full-library membership survives relaunch without a certificate")
    func emptyMembershipPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        do {
            let store = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await store.initialize()
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: [MusicDatabaseTrackID]()),
                repairs: [],
                upserts: [],
                certificates: .invalidate(.membershipChanged)
            ))
        }

        let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await relaunched.initialize()
        let snapshot = try await relaunched.loadMirrorSnapshot()
        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.certificates.isEmpty)
    }

    @Test("Mirror revision advances across commits and survives relaunch")
    func revisionPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorRevision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")

        do {
            let store = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await store.initialize()
            let initialTracks = [track(id: "keep"), track(id: "delete")]
            let first = try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: initialTracks),
                repairs: [],
                upserts: initialTracks,
                certificates: .invalidate(.membershipChanged)
            ))
            let second = try await store.commitMirror(MirrorCommit(
                baseRevision: first.revision,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve
            ))
            #expect(first.revision == MirrorRevision(value: 1))
            #expect(second.revision == MirrorRevision(value: 2))
        }

        let expectedSnapshot: TrackMirrorSnapshot
        do {
            let relaunched = try TrackDataStore(modelContainer: makeContainer(at: url))
            try await relaunched.initialize()
            expectedSnapshot = try await relaunched.loadMirrorSnapshot()
            #expect(expectedSnapshot.revision == MirrorRevision(value: 2))
            #expect(expectedSnapshot.certificates.isEmpty)

            await #expect(throws: MirrorRevisionConflict(
                expected: MirrorRevision(value: 1),
                actual: MirrorRevision(value: 2)
            )) {
                try await relaunched.commitMirror(MirrorCommit(
                    baseRevision: MirrorRevision(value: 1),
                    inventoryChange: replacementInventory(for: [
                        track(id: "keep", name: "Changed"),
                        track(id: "insert"),
                    ]),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")],
                    certificates: .invalidate(.incompleteObservation)
                ))
            }
            #expect(try await relaunched.loadMirrorSnapshot() == expectedSnapshot)
        }

        let reopened = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await reopened.initialize()
        #expect(try await reopened.loadMirrorSnapshot() == expectedSnapshot)
    }

    @Test("A mirror commit returns the exact snapshot accepted by its transaction")
    func commitReturnsAcceptedSnapshot() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let inserted = track(id: "inserted")

        let result = try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: replacementInventory(for: [inserted]),
            repairs: [],
            upserts: [inserted],
            certificates: .invalidate(.membershipChanged)
        ))

        #expect(result.snapshot.revision == result.revision)
        #expect(result.snapshot.presentTracks == [inserted])
    }

    @Test("A populated synchronization audit survives repeated relaunch")
    func synchronizationAuditSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")
        let fixture = try makeAuditFixture()
        try await persistAudit(fixture, at: url)

        var persistedCompletion: Date?
        for _ in 0 ..< 2 {
            let container = try makeContainer(at: url)
            let stored = try #require(ModelContext(container).fetch(FetchDescriptor<PersistedSyncRecord>()).first)
            assertAudit(stored, matches: fixture)
            if let persistedCompletion {
                #expect(stored.completedAt == persistedCompletion)
            } else {
                persistedCompletion = stored.completedAt
            }
        }
    }

    private struct SyncAuditFixture {
        let track: Track
        let membership: MembershipStamp
        let observation: ObservationID
        let scopeID: UUID
        let certificateID: UUID
        let startedAt: Date
        let preparedAt: Date
        let record: MirrorSyncRecord
        let certificate: ScopeCertificate
    }

    private func makeAuditFixture() throws -> SyncAuditFixture {
        let insertedTrack = track(id: "inserted")
        let membership = try MembershipFingerprint.make(ids: [databaseID("inserted")])
        let observation = ObservationID()
        let scopeID = UUID()
        let certificateID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let preparedAt = startedAt.addingTimeInterval(11)
        let record = try MirrorSyncRecord(
            observation: observation,
            revisions: MirrorSyncRevisions(base: .initial, committed: MirrorRevision(value: 1)),
            evidence: MirrorSyncEvidence(
                membership: membership,
                scopeID: scopeID,
                certificateID: certificateID
            ),
            mode: .force,
            window: MirrorSyncWindow(startedAt: startedAt, preparedAt: preparedAt),
            delta: MirrorSyncCounts(new: 1, modified: 2, identityChanged: 3, refreshed: 4, removed: 5),
            coverage: MirrorSyncCoverage(
                identityRequestedCount: 7,
                identityObservedCount: 6,
                metadataRequestedCount: 9,
                metadataObservedCount: 8,
                isMembershipComplete: true,
                isIdentityComplete: false,
                isMetadataComplete: false
            )
        )
        let certificate = ScopeCertificate(
            id: certificateID,
            revision: MirrorRevision(value: 1),
            membership: membership,
            testArtists: [],
            fieldSet: .processingV1,
            evidence: ScopeEvidence(
                requestedFingerprint: membership.fingerprint,
                observedFingerprint: membership.fingerprint,
                trackCount: 1
            ),
            observedAt: preparedAt
        )
        return SyncAuditFixture(
            track: insertedTrack,
            membership: membership,
            observation: observation,
            scopeID: scopeID,
            certificateID: certificateID,
            startedAt: startedAt,
            preparedAt: preparedAt,
            record: record,
            certificate: certificate
        )
    }

    private func persistAudit(_ fixture: SyncAuditFixture, at url: URL) async throws {
        let store = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await store.initialize()
        try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            observation: fixture.observation,
            inventoryChange: replacementInventory(for: [fixture.track]),
            repairs: [],
            upserts: [fixture.track],
            certificates: .replace(fixture.certificate),
            syncRecord: fixture.record
        ))
    }

    private func assertAudit(_ stored: PersistedSyncRecord, matches fixture: SyncAuditFixture) {
        #expect(stored.observationID == fixture.observation.value)
        #expect(stored.baseRevisionValue == 0)
        #expect(stored.committedRevisionValue == 1)
        #expect(stored.membershipFingerprint == fixture.membership.fingerprint)
        #expect(stored.scopeID == fixture.scopeID)
        #expect(stored.certificateID == fixture.certificateID)
        #expect(stored.modeRaw == MirrorSyncMode.force.rawValue)
        #expect(stored.startedAt == fixture.startedAt)
        #expect(stored.completedAt >= fixture.preparedAt)
        #expect(stored.newCount == 1)
        #expect(stored.modifiedCount == 2)
        #expect(stored.identityChangedCount == 3)
        #expect(stored.refreshedCount == 4)
        #expect(stored.removedCount == 5)
        #expect(stored.identityRequestedCount == 7)
        #expect(stored.identityObservedCount == 6)
        #expect(stored.metadataRequestedCount == 9)
        #expect(stored.metadataObservedCount == 8)
        #expect(stored.isMembershipComplete)
        #expect(!stored.isIdentityComplete)
        #expect(!stored.isMetadataComplete)
        #expect(stored.outcomeRaw == MirrorSyncOutcome.committed.rawValue)
    }

    @Test("Synchronization audit retention keeps only the configured newest records")
    func auditHonorsRetention() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        var revision = MirrorRevision.initial

        for index in 1 ... 3 {
            let observation = ObservationID()
            let committedRevision = try revision.advanced()
            let record = try MirrorSyncRecord(
                observation: observation,
                revisions: MirrorSyncRevisions(base: revision, committed: committedRevision),
                evidence: MirrorSyncEvidence(
                    membership: MembershipFingerprint.make(ids: []),
                    scopeID: UUID(),
                    certificateID: nil
                ),
                mode: .membershipOnly,
                window: MirrorSyncWindow(
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    preparedAt: Date(timeIntervalSince1970: TimeInterval(index))
                ),
                delta: MirrorSyncCounts(new: 0, modified: 0, identityChanged: 0, refreshed: 0, removed: 0),
                coverage: MirrorSyncCoverage(
                    identityRequestedCount: 0,
                    identityObservedCount: 0,
                    metadataRequestedCount: 0,
                    metadataObservedCount: 0,
                    isMembershipComplete: true,
                    isIdentityComplete: true,
                    isMetadataComplete: true
                )
            )
            let result = try await store.commitMirror(MirrorCommit(
                baseRevision: revision,
                observation: observation,
                inventoryChange: .preserve,
                repairs: [],
                upserts: [],
                certificates: .preserve,
                syncRecord: record,
                syncRecordLimit: 2
            ))
            revision = result.revision
        }

        let descriptor = FetchDescriptor<PersistedSyncRecord>(
            sortBy: [SortDescriptor(\.committedRevisionValue)]
        )
        let records = try ModelContext(container).fetch(descriptor)
        #expect(records.map(\.committedRevisionValue) == [2, 3])
    }

    @Test("A cancelled task cannot enter the mirror transaction")
    func cancellationStopsMirrorTransaction() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let commit = MirrorCommit(
            baseRevision: .initial,
            inventoryChange: .preserve,
            repairs: [],
            upserts: [],
            certificates: .preserve
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.commitMirror(commit)
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(try await store.loadMirrorSnapshot().revision == .initial)
    }

    @Test("Maximum persisted revision rejects a commit without mutating the mirror")
    func maximumRevisionRollsBack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMirrorExhaustion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tracks.store")
        let expectedSnapshot: TrackMirrorSnapshot
        do {
            let container = try makeContainer(at: url)
            let context = ModelContext(container)
            context.insert(PersistedMirrorState(revisionValue: .max))
            try context.insert(PersistedTrack(mirror: track(id: "keep"), databaseID: databaseID("keep")))
            try context.insert(PersistedTrack(mirror: track(id: "delete"), databaseID: databaseID("delete")))
            context.insert(PersistedLibraryMember(
                databaseID: "keep",
                isPresent: true,
                firstSeenRevisionValue: .max
            ))
            context.insert(PersistedLibraryMember(
                databaseID: "delete",
                isPresent: true,
                firstSeenRevisionValue: .max
            ))
            try context.save()
            let store = TrackDataStore(modelContainer: container)
            expectedSnapshot = try await store.loadMirrorSnapshot()

            do {
                _ = try await store.commitMirror(MirrorCommit(
                    baseRevision: expectedSnapshot.revision,
                    inventoryChange: replacementInventory(for: [
                        track(id: "keep", name: "Changed"),
                        track(id: "insert"),
                    ]),
                    repairs: [],
                    upserts: [track(id: "keep", name: "Changed"), track(id: "insert")],
                    certificates: .invalidate(.membershipChanged)
                ))
                Issue.record("A mirror commit must fail when its revision is exhausted")
            } catch {
                #expect(error.localizedDescription == "Mirror revision exhausted at \(UInt64.max).")
            }
            #expect(try await store.loadMirrorSnapshot() == expectedSnapshot)
        }

        let reopened = try TrackDataStore(modelContainer: makeContainer(at: url))
        try await reopened.initialize()
        #expect(try await reopened.loadMirrorSnapshot() == expectedSnapshot)
    }

    @Test("Mismatched synchronization evidence rolls back the atomic mirror commit")
    func invalidSyncEvidenceRollsBack() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        let memberID = try databaseID("A")
        let inventory = try replacementInventory(for: [memberID])
        let certificate = try scopeCertificate(
            revision: MirrorRevision(value: 1),
            inventoryChange: inventory,
            trackIDs: [memberID]
        )
        let observation = ObservationID()
        let record = try MirrorSyncRecord(
            observation: observation,
            revisions: MirrorSyncRevisions(base: .initial, committed: MirrorRevision(value: 1)),
            evidence: MirrorSyncEvidence(
                membership: certificate.membership,
                scopeID: UUID(),
                certificateID: UUID()
            ),
            mode: .force,
            window: MirrorSyncWindow(
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                preparedAt: Date(timeIntervalSince1970: 1_800_000_001)
            ),
            delta: MirrorSyncCounts(new: 1, modified: 0, identityChanged: 0, refreshed: 0, removed: 0),
            coverage: MirrorSyncCoverage(
                identityRequestedCount: 1,
                identityObservedCount: 1,
                metadataRequestedCount: 1,
                metadataObservedCount: 1,
                isMembershipComplete: true,
                isIdentityComplete: true,
                isMetadataComplete: true
            )
        )

        await #expect(throws: TrackStoreError.invalidSyncRecord) {
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                observation: observation,
                inventoryChange: inventory,
                repairs: [],
                upserts: [track(id: "A")],
                certificates: .replace(certificate),
                syncRecord: record
            ))
        }

        let snapshot = try await store.loadMirrorSnapshot()
        #expect(snapshot.revision == .initial)
        #expect(snapshot.presentIDs.isEmpty)
        #expect(snapshot.presentTracks.isEmpty)
        #expect(snapshot.certificates.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<PersistedSyncRecord>()).isEmpty)
    }
}
