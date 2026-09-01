import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Library sync identity repair")
struct LibrarySyncRepairTests {
    @Test("Direct database identity repairs one legacy row")
    func repairsDirectIdentity() async throws {
        let legacy = legacyTrack(sourceID: "MK1", databaseID: "AS1", originalArtist: "Before")
        let fixture = try makeFixture(
            stored: [legacy],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1")]
        )

        let result = try await fixture.service.synchronizeNow()

        let request = try #require(await fixture.reader.requests.first)
        #expect(request.refresh == .force)
        let update = try #require(await fixture.store.updates.first)
        let repair = try #require(update.repairs.first)
        #expect(update.repairs.count == 1)
        #expect(result.mirrorMaintenanceCount == 1)
        #expect(result.hasMirrorChanges)
        #expect(repair.sourceIDs == ["MK1"])
        #expect(repair.target.id == "AS1")
        #expect(repair.target.appleScriptID == "AS1")
        #expect(repair.target.originalArtist == "Before")
        #expect(update.upserts.isEmpty)
        #expect(inventoryIDs(update.inventoryChange)?.map(\.rawValue) == ["AS1"])
    }

    @Test("Unique metadata identity repairs a row without direct evidence")
    func repairsUniqueFallbackIdentity() async throws {
        let legacy = legacyTrack(sourceID: "MK1", databaseID: nil)
        let fixture = try makeFixture(
            stored: [legacy],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.map(\.sourceIDs) == [["MK1"]])
        #expect(update.repairs.map(\.target.id) == ["AS1"])
    }

    @Test("A manual sync converges duplicate MusicKit aliases onto one Music database track")
    func convergesDuplicateAliases() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "-1041391495849775059", databaseID: nil, name: "Wicked Game"),
                legacyTrack(sourceID: "i.b15B0L9fqNNzE1", databaseID: nil, name: "Wicked Game"),
                canonicalTrack(id: "103401", name: "Wicked Game"),
            ],
            currentIDs: ["103401"],
            rows: [row(id: "103401", name: "Wicked Game")]
        )

        let result = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(result.changeCount == 0)
        #expect(result.mirrorMaintenanceCount == 2)
        #expect(result.hasMirrorChanges)
        #expect(await fixture.store.stored.map(\.id) == ["103401"])
        #expect(await fixture.store.updates.count == 1)
        let repairedIdentity = AlbumIdentity(artist: "Artist", album: "Album")
        #expect(update.effects == [
            .invalidateAlbumYear(repairedIdentity),
            .invalidateAPIResults(repairedIdentity),
            .invalidateSnapshot,
            .refreshProjections,
        ])
    }

    @Test("A manual sync atomically converges aliases in the persisted mirror")
    func convergesStoredAliases() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        let canonical = PersistedTrack(
            trackID: "103401", appleScriptID: "103401", name: "Wicked Game", artist: "In Flames",
            album: "Down, Wicked & No Good", genreUpdated: true
        )
        let numericAlias = PersistedTrack(
            trackID: "-1041391495849775059", name: "Wicked Game", artist: "In Flames",
            album: "Down, Wicked & No Good", yearUpdated: true, originalAlbum: "Down, Wicked & No Good"
        )
        let libraryAlias = PersistedTrack(
            trackID: "i.b15B0L9fqNNzE1", name: "Wicked Game", artist: "In Flames",
            album: "Down, Wicked & No Good", originalAlbum: "Down, Wicked & No Good"
        )
        let history = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: .now, changeTypeRaw: ChangeType.yearUpdate.rawValue,
            trackID: numericAlias.trackID, artist: "In Flames", trackName: "Wicked Game",
            albumName: "Down, Wicked & No Good"
        )
        history.track = numericAlias
        context.insert(canonical)
        context.insert(numericAlias)
        context.insert(libraryAlias)
        context.insert(history)
        try context.save()

        let databaseID = try databaseID("103401")
        let reader = try RepairObservationReader(template: RepairObservationTemplate(
            rows: [row(
                id: databaseID.rawValue,
                name: "Wicked Game",
                artist: "In Flames",
                album: "Down, Wicked & No Good"
            )],
            censusIDs: [databaseID],
            currentIDs: [databaseID],
            membership: .full,
            generation: #require(LibraryGeneration(sourceValue: "repair-generation"))
        ))
        let store = TrackDataStore(modelContainer: container)
        let service = LibrarySyncService(trackStore: store, observer: reader)

        _ = try await service.synchronizeNow()

        let verification = ModelContext(container)
        let tracks = try verification.fetch(FetchDescriptor<PersistedTrack>())
        let entries = try verification.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.trackID == databaseID.rawValue)
        #expect(track.genreUpdated)
        #expect(track.yearUpdated)
        #expect(track.originalAlbum == "Down, Wicked & No Good")
        #expect(entries.count == 1)
        #expect(entries.first?.trackID == databaseID.rawValue)
        #expect(entries.first?.track?.trackID == databaseID.rawValue)
    }

    @Test("Grouped repairs invalidate and clear every source album identity")
    func groupedRepairsInvalidateSources() async throws {
        let pending = PendingVerificationProbe(entries: [
            PendingAlbumEntry(
                id: "first-source",
                artist: "First Artist",
                album: "First Album",
                reason: "prerelease"
            ),
            PendingAlbumEntry(
                id: "second-source",
                artist: "Second Artist",
                album: "Second Album",
                reason: "prerelease"
            ),
        ], isVerificationNeeded: true)
        let fixture = try makeFixture(
            stored: [
                legacyTrack(
                    sourceID: "MK1",
                    databaseID: "AS1",
                    artist: "First Artist",
                    album: "First Album",
                    trackStatus: TrackKind.prerelease.rawValue
                ),
                legacyTrack(
                    sourceID: "MK2",
                    databaseID: "AS1",
                    artist: "Second Artist",
                    album: "Second Album",
                    trackStatus: TrackKind.prerelease.rawValue
                ),
            ],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1", artist: "Current Artist", album: "Current Album")],
            pendingVerification: pending
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        let invalidatedIdentities = update.effects.compactMap { effect -> AlbumIdentity? in
            guard case let .invalidateAlbumYear(identity) = effect else { return nil }
            return identity
        }
        #expect(Set(invalidatedIdentities).isSuperset(of: Set([
            AlbumIdentity(artist: "First Artist", album: "First Album"),
            AlbumIdentity(artist: "Second Artist", album: "Second Album"),
        ])))
        let removals = await pending.removedAlbums
        #expect(Set(removals.map { AlbumIdentity(artist: $0.artist, album: $0.album) }) == Set([
            AlbumIdentity(artist: "First Artist", album: "First Album"),
            AlbumIdentity(artist: "Second Artist", album: "Second Album"),
        ]))
    }

    @Test("A complete observation retires a removed evidence-free MusicKit alias")
    func retiresRemovedLegacyAlias() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "i.WmLzgRkcDNNqGE", databaseID: nil, name: "The Great Deceiver"),
                canonicalTrack(id: "103401", name: "Wicked Game"),
            ],
            currentIDs: ["103401"],
            rows: [row(id: "103401", name: "Wicked Game")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(await fixture.store.stored.map(\.id) == ["103401"])
        #expect(await fixture.store.updates.count == 1)
        let retiredIdentity = AlbumIdentity(artist: "Artist", album: "Album")
        #expect(update.effects == [
            .invalidateAlbumYear(retiredIdentity),
            .invalidateAPIResults(retiredIdentity),
            .invalidateSnapshot,
            .refreshProjections,
        ])
    }

    @Test("Retiring a prerelease alias clears its pending verification entry")
    func retiredAliasClearsPrereleasePendingEntry() async throws {
        let pending = PendingVerificationProbe(
            entry: PendingAlbumEntry(
                id: "retired-prerelease",
                artist: "Retired Artist",
                album: "Retired Album",
                reason: "prerelease"
            ),
            isVerificationNeeded: true
        )
        let retiredAlias = Track(
            id: "legacy-alias",
            name: "Retired Song",
            artist: "Retired Artist",
            album: "Retired Album",
            trackStatus: TrackKind.prerelease.rawValue
        )
        let fixture = try makeFixture(
            stored: [retiredAlias, canonicalTrack(id: "103401", name: "Current Song")],
            currentIDs: ["103401"],
            rows: [row(id: "103401", name: "Current Song")],
            pendingVerification: pending
        )

        _ = try await fixture.service.synchronizeNow()

        let removals = await pending.removedAlbums
        #expect(removals.count == 1)
        #expect(removals.first?.artist == "Retired Artist")
        #expect(removals.first?.album == "Retired Album")
    }

    @Test("Incomplete metadata preserves a census-present legacy alias")
    func preservesAliasOnPartialRead() async throws {
        let fixture = try makeFixture(
            stored: [legacyTrack(sourceID: "MK1", databaseID: "AS1")],
            currentIDs: ["AS1"],
            rows: []
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.retiredAliasIDs.isEmpty)
        #expect(await fixture.store.stored.map(\.id) == ["MK1"])
    }

    @Test("Scoped metadata coverage cannot retire an unresolved legacy alias")
    func preservesScopedAlias() async throws {
        let legacy = legacyTrack(sourceID: "MK-OUT", databaseID: nil, artist: "Target")
        let fixture = try makeFixture(
            stored: [legacy],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1", name: "Different", artist: "Target")],
            testArtists: ["Target"],
            membership: .scoped(unobservedIDs: [])
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.retiredAliasIDs.isEmpty)
        #expect(await fixture.store.stored.map(\.id) == ["AS1", "MK-OUT"])
    }

    @Test("Unique metadata identity repairs an artistless legacy row")
    func repairsArtistlessTrack() async throws {
        let legacy = legacyTrack(sourceID: "MK1", databaseID: nil, artist: "")
        let fixture = try makeFixture(
            stored: [legacy],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1", artist: "")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.map(\.sourceIDs) == [["MK1"]])
        #expect(update.repairs.map(\.target.id) == ["AS1"])
    }

    @Test("An evidence-free ambiguous alias is retired for store validation")
    func retiresAmbiguousFallback() async throws {
        let fixture = try makeFixture(
            stored: [legacyTrack(sourceID: "MK1", databaseID: nil)],
            currentIDs: ["AS1", "AS2"],
            rows: [row(id: "AS2"), row(id: "AS1")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.isEmpty)
        #expect(update.retiredAliasIDs == ["MK1"])
    }

    @Test("An evidence-free unresolved alias is retired for store validation")
    func retiresUnresolvedFallback() async throws {
        let fixture = try makeFixture(
            stored: [legacyTrack(sourceID: "MK1", databaseID: nil)],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1", name: "Different")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.isEmpty)
        #expect(update.retiredAliasIDs == ["MK1"])
    }

    @Test("An evidence-free unresolved artistless alias is retired for store validation")
    func retiresArtistlessMismatch() async throws {
        let legacy = legacyTrack(
            sourceID: "MK1",
            databaseID: nil,
            name: "Artistless Song",
            artist: ""
        )
        let fixture = try makeFixture(
            stored: [legacy],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1", name: "Different Song", artist: "")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.isEmpty)
        #expect(update.retiredAliasIDs == ["MK1"])
    }

    @Test("Canonical row converges a legacy repair")
    func convergesCanonicalTargetCollision() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "MK1", databaseID: "AS1"),
                canonicalTrack(id: "AS1")
            ],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1")]
        )

        _ = try await fixture.service.synchronizeNow()

        #expect(await fixture.store.stored.map(\.id) == ["AS1"])
        #expect(await fixture.store.updates.count == 1)
    }

    @Test("Two legacy aliases converge onto one repair target")
    func groupsDuplicateRepairTarget() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "MK2", databaseID: "AS1"),
                legacyTrack(sourceID: "MK1", databaseID: "AS1")
            ],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.map(\.sourceIDs) == [["MK1", "MK2"]])
        #expect(update.repairs.map(\.target.id) == ["AS1"])
        #expect(update.retiredAliasIDs.isEmpty)
    }

    @Test("A same-ID legacy row converges with aliases for its target")
    func groupsSameIDLegacyTarget() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "AS1", databaseID: nil),
                legacyTrack(sourceID: "MK1", databaseID: "AS1"),
            ],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1")]
        )

        _ = try await fixture.service.synchronizeNow()

        let update = try #require(await fixture.store.updates.first)
        #expect(update.repairs.map(\.sourceIDs) == [["AS1", "MK1"]])
        #expect(await fixture.store.stored.map(\.id) == ["AS1"])
    }

    @Test("Scoped sync preserves legacy rows outside its artist scope")
    func preservesOutsideScopeLegacyRows() async throws {
        let target = canonicalTrack(id: "A", artist: "Target")
        let outside = legacyTrack(sourceID: "MK-OUT", databaseID: "AS-OUT", artist: "Other")
        let fixture = try makeFixture(
            stored: [outside, target],
            currentIDs: ["A"],
            rows: [],
            testArtists: ["Target"],
            membership: .scoped(unobservedIDs: [])
        )

        _ = try await fixture.service.synchronizeNow()

        let request = try #require(await fixture.reader.requests.first)
        #expect(request.refresh == .fast)
        #expect(await fixture.store.stored.map(\.id).sorted() == ["A", "MK-OUT"])
    }

    @Test("Full verification checks present membership without consuming repair candidates")
    func verifiesPresentMembership() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "MK1", databaseID: "AS1"),
                canonicalTrack(id: "AS1"),
            ],
            currentIDs: ["AS1"],
            rows: []
        )

        let result = try await fixture.service.verifyAndCleanDatabase(force: true)

        #expect(result.verifiedTrackCount == 1)
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await fixture.reader.requests.count == 1)
        #expect(await fixture.store.updates.count == 1)
        #expect(await fixture.store.stored.map(\.id).sorted() == ["AS1", "MK1"])
    }

    @Test("Scoped verification checks present membership without consuming in-scope repair candidates")
    func verifiesScopedMembership() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "MK1", databaseID: "AS1", artist: "Target"),
                canonicalTrack(id: "AS1", artist: "Target"),
            ],
            currentIDs: ["AS1"],
            rows: [],
            testArtists: ["Target"],
            membership: .scoped(unobservedIDs: [])
        )

        let result = try await fixture.service.verifyAndCleanDatabase(force: true)

        #expect(result.verifiedTrackCount == 1)
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await fixture.reader.requests.count == 1)
        #expect(await fixture.store.updates.count == 1)
        #expect(await fixture.store.stored.map(\.id).sorted() == ["AS1", "MK1"])
    }

    @Test("Detection plans repair without mutating the store")
    func detectionIsReadOnly() async throws {
        let fixture = try makeFixture(
            stored: [legacyTrack(sourceID: "MK1", databaseID: "AS1")],
            currentIDs: ["AS1"],
            rows: [row(id: "AS1")]
        )

        _ = try await fixture.service.detectObservation().result

        #expect(await fixture.store.updates.isEmpty)
        #expect(await fixture.store.stored.map(\.id) == ["MK1"])
    }

    @Test("Same raw ID repair canonicalizes a persisted legacy row")
    func repairsSameRawIDInTrackStore() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "AS1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            genre: "Rock",
            year: 1999,
            yearBeforeMGU: 1998,
            yearSetByMGU: 1999
        ))
        try context.save()
        let store = TrackDataStore(modelContainer: container)
        let databaseID = try databaseID("AS1")
        let reader = try RepairObservationReader(template: RepairObservationTemplate(
            rows: [row(id: "AS1")],
            censusIDs: [databaseID],
            currentIDs: [databaseID],
            membership: .full,
            generation: #require(LibraryGeneration(sourceValue: "repair-generation"))
        ))
        let service = LibrarySyncService(trackStore: store, observer: reader)

        _ = try await service.synchronizeNow()

        let repaired = try #require(try await store.getTrack(byID: "AS1"))
        #expect(repaired.appleScriptID == "AS1")
        #expect(repaired.yearBeforeMGU == 1998)
        #expect(try await store.trackCount() == 1)
    }

    @Test("Synchronize commits repair additions and removals in one update")
    func commitsOneMixedUpdate() async throws {
        let fixture = try makeFixture(
            stored: [
                legacyTrack(sourceID: "MK1", databaseID: "AS1"),
                canonicalTrack(id: "REMOVED", name: "Old")
            ],
            currentIDs: ["AS1", "NEW"],
            rows: [row(id: "NEW", name: "New"), row(id: "AS1")]
        )

        let result = try await fixture.service.synchronizeNow()

        #expect(result.newTracks.map(\.id) == ["NEW"])
        #expect(result.removedTrackIDs == ["REMOVED"])
        let update = try #require(await fixture.store.updates.first)
        #expect(await fixture.store.updates.count == 1)
        #expect(update.repairs.map(\.sourceIDs) == [["MK1"]])
        #expect(update.upserts.map(\.id) == ["NEW"])
        #expect(inventoryIDs(update.inventoryChange)?.map(\.rawValue) == ["AS1", "NEW"])
    }

    private func makeFixture(
        stored: [Track],
        currentIDs: [String],
        rows: [LibraryTrackRow],
        testArtists: [String] = [],
        membership: MembershipCompleteness = .full,
        pendingVerification: (any PendingVerificationService)? = nil
    ) throws -> RepairFixture {
        let ids = try databaseIDs(currentIDs)
        let reader = try RepairObservationReader(template: RepairObservationTemplate(
            rows: rows,
            censusIDs: ids,
            currentIDs: ids,
            membership: membership,
            generation: #require(LibraryGeneration(sourceValue: "repair-generation"))
        ))
        let store = RepairMirrorStore(stored: stored)
        let logsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibrarySyncRepairTests-\(UUID().uuidString)", isDirectory: true)
        let service = LibrarySyncService(
            trackStore: store,
            pendingVerificationService: pendingVerification,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(
                logsBaseDirectory: logsDirectory.path,
                testArtists: testArtists
            ),
            observer: reader
        )
        return RepairFixture(store: store, reader: reader, service: service)
    }

    private func row(
        id: String,
        name: String = "Song",
        artist: String = "Artist",
        album: String = "Album"
    ) throws -> LibraryTrackRow {
        try LibraryTrackRow(
            databaseID: databaseID(id),
            metadata: LibraryTrackMetadata(
                text: LibraryTrackText(
                    name: .value(name),
                    artist: .value(artist),
                    album: .value(album),
                    albumArtist: .absent
                ),
                genre: .value("Metal"),
                editableYear: .value(2001),
                releaseYear: .absent,
                dateAdded: .absent,
                lastModified: .absent,
                status: .absent
            )
        )
    }

    private func legacyTrack(
        sourceID: String,
        databaseID: String?,
        name: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        originalArtist: String? = nil,
        trackStatus: String? = nil
    ) -> Track {
        Track(
            id: sourceID,
            name: name,
            artist: artist,
            album: album,
            genre: "Rock",
            year: 1999,
            trackStatus: trackStatus,
            originalArtist: originalArtist,
            yearBeforeMGU: 1998,
            yearSetByMGU: 1999,
            appleScriptID: databaseID
        )
    }

    private func canonicalTrack(
        id: String,
        name: String = "Song",
        artist: String = "Artist"
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: artist,
            album: "Album",
            genre: "Metal",
            year: 2001,
            appleScriptID: id
        )
    }

    private func databaseIDs(_ values: [String]) throws -> Set<MusicDatabaseTrackID> {
        try Set(values.map(databaseID))
    }

    private func databaseID(_ value: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: value))
    }
}

private struct RepairFixture {
    let store: RepairMirrorStore
    let reader: RepairObservationReader
    let service: LibrarySyncService
}

private struct RepairObservationTemplate: Sendable {
    let rows: [LibraryTrackRow]
    let censusIDs: Set<MusicDatabaseTrackID>
    let currentIDs: Set<MusicDatabaseTrackID>
    let membership: MembershipCompleteness
    let generation: LibraryGeneration
}

private actor RepairObservationReader: MusicAppReading {
    private let template: RepairObservationTemplate
    private(set) var requests: [LibraryObservationRequest] = []

    init(template: RepairObservationTemplate) {
        self.template = template
    }

    func observe(_ request: LibraryObservationRequest) -> LibraryObservation {
        requests.append(request)
        let censusIDs = template.censusIDs.sorted { $0.rawValue < $1.rawValue }
        let identityLookups = request.identityLookupIDs(in: censusIDs)
        let metadataLookups = request.metadataLookupIDs(
            in: censusIDs,
            admittedIDs: template.currentIDs
        )
        let identityIDs = request.reportedIdentityIDs(
            identityLookupIDs: identityLookups,
            metadataLookupIDs: metadataLookups
        )
        let identities = template.rows.map(\.identityRow).filter { identityIDs.contains($0.databaseID) }
        let observedIDs = Set(template.rows.map(\.databaseID))
        return LibraryObservation(
            tracks: template.rows,
            identities: identities,
            epoch: LibraryObservationEpoch(
                censusIDs: template.censusIDs,
                currentIDs: template.currentIDs,
                scope: request.scope,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                generation: template.generation
            ),
            coverage: LibraryObservationCoverage(
                membership: template.membership,
                identity: IdentityCompleteness(
                    requestedIDs: identityIDs,
                    observedIDs: Set(identities.map(\.databaseID))
                ),
                metadata: MetadataCompleteness(
                    requestedIDs: Set(metadataLookups),
                    observedIDs: observedIDs
                ),
                issues: []
            )
        )
    }
}

private actor RepairMirrorStore: TrackStateStore {
    private(set) var stored: [Track]
    private(set) var updates: [MirrorCommit] = []
    private var revision = MirrorRevision.initial
    private var certificates: [ScopeCertificate] = []

    init(stored: [Track]) {
        self.stored = stored
    }

    func initialize() async throws {
        // The test provides initialized mirror state and does not exercise initialization persistence.
    }

    func loadMirrorSnapshot() async throws -> TrackMirrorSnapshot {
        try mirrorSnapshot(revision: revision, tracks: stored, certificates: certificates)
    }

    @discardableResult
    func commitMirror(_ update: MirrorCommit) async throws -> MirrorCommitResult {
        guard update.baseRevision == revision else {
            throw MirrorRevisionConflict(expected: update.baseRevision, actual: revision)
        }
        let nextRevision = try revision.advanced()
        updates.append(update)
        for repair in update.repairs {
            stored.removeAll { repair.sourceIDs.contains($0.id) }
            if let index = stored.firstIndex(where: { $0.id == repair.target.id }) {
                stored[index] = repair.target
            } else {
                stored.append(repair.target)
            }
        }
        stored.removeAll { update.retiredAliasIDs.contains($0.id) }
        applyInventory(update.inventoryChange, to: &stored)
        for track in update.upserts {
            stored.removeAll { $0.id == track.id }
            stored.append(track)
        }
        switch update.certificates {
        case .preserve:
            break
        case let .replace(certificate), let .rebase(certificate):
            certificates = [certificate]
        case .invalidate:
            certificates = []
        }
        stored.sort { $0.id < $1.id }
        revision = nextRevision
        return try MirrorCommitResult(
            revision: revision,
            snapshot: mirrorSnapshot(revision: revision, tracks: stored, certificates: certificates)
        )
    }

    func getTrack(byID id: String) async throws -> Track? {
        stored.first { $0.id == id }
    }

    func commitAppliedChange(_: ChangeLogEntry) async throws -> MirrorRevision {
        // The test exercises mirror reconciliation, not change-log persistence.
        revision
    }
    func commitObservedChange(_ change: ChangeLogEntry) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }
    func commitRevertedChange(
        _ change: ChangeLogEntry,
        removingHistoryEntryID _: UUID
    ) async throws -> MirrorRevision {
        try await commitAppliedChange(change)
    }

    func getUnprocessedTracks() async throws -> [Track] {
        stored
    }

    func trackCount() async throws -> Int {
        stored.count
    }
}
