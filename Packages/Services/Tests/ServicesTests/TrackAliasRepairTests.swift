import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

@Suite("Track alias repair")
struct TrackAliasRepairTests {
    @Test("Grouped alias repair preserves processing state and every history entry")
    func preservesGroupedEvidence() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        let canonical = PersistedTrack(
            trackID: "103401", appleScriptID: "103401", name: "Wicked Game", artist: "In Flames",
            album: "Down, Wicked & No Good", genreUpdated: true, processedDate: earlier
        )
        let numericAlias = PersistedTrack(
            trackID: "-1041391495849775059", name: "Wicked Game", artist: "In Flames",
            album: "Down, Wicked & No Good", yearUpdated: true, processedDate: later,
            originalAlbum: "Down, Wicked & No Good", yearBeforeMGU: 2016, yearSetByMGU: 2017
        )
        let libraryAlias = PersistedTrack(
            trackID: "i.b15B0L9fqNNzE1", name: "Wicked Game", artist: "In Flames",
            album: "Down, Wicked & No Good", originalAlbum: "Down, Wicked & No Good",
            yearBeforeMGU: 2016, yearSetByMGU: 2017
        )
        let linked = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: later, changeTypeRaw: ChangeType.yearUpdate.rawValue,
            trackID: numericAlias.trackID, artist: "In Flames", trackName: "Wicked Game",
            albumName: "Down, Wicked & No Good"
        )
        linked.track = numericAlias
        let unlinked = PersistedChangeLogEntry(
            entryID: UUID(), timestamp: later, changeTypeRaw: ChangeType.albumCleaning.rawValue,
            trackID: libraryAlias.trackID, artist: "In Flames", trackName: "Wicked Game",
            albumName: "Down, Wicked & No Good"
        )
        context.insert(canonical)
        context.insert(numericAlias)
        context.insert(libraryAlias)
        context.insert(linked)
        context.insert(unlinked)
        try context.save()
        let store = TrackDataStore(modelContainer: container)

        try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: replacementInventory(for: [testDatabaseID("103401")]),
            repairs: [TrackMirrorRepair(
                sourceIDs: [numericAlias.trackID, libraryAlias.trackID],
                target: mirrorTrack(id: "103401", name: "Wicked Game")
            )],
            upserts: [],
            certificates: .invalidate(.membershipChanged)
        ))

        let verification = ModelContext(container)
        let tracks = try verification.fetch(FetchDescriptor<PersistedTrack>())
        let history = try verification.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let merged = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(merged.trackID == "103401")
        #expect(merged.genreUpdated)
        #expect(merged.yearUpdated)
        #expect(merged.processedDate == later)
        #expect(merged.originalAlbum == "Down, Wicked & No Good")
        #expect(merged.yearBeforeMGU == 2016)
        #expect(merged.yearSetByMGU == 2017)
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.trackID == "103401" && $0.track?.trackID == "103401" })
    }

    @Test("An evidence-free removed alias is retired atomically")
    func retiresEvidenceFreeAlias() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "i.WmLzgRkcDNNqGE", name: "The Great Deceiver", artist: "In Flames",
            album: "The Great Deceiver - Single"
        ))
        try context.save()
        let store = TrackDataStore(modelContainer: container)

        try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: replacementInventory(for: [MusicDatabaseTrackID]()),
            repairs: [],
            retiredAliasIDs: ["i.WmLzgRkcDNNqGE"],
            upserts: [],
            certificates: .invalidate(.membershipChanged)
        ))

        #expect(try await store.getHistoricalTrack(byID: "i.WmLzgRkcDNNqGE") == nil)
    }

    @Test("A removed alias with durable evidence fails closed")
    func rejectsStatefulRetirement() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "legacy", name: "Song", artist: "Artist", album: "Album", genreUpdated: true
        ))
        try context.save()
        let store = TrackDataStore(modelContainer: container)

        await #expect(throws: TrackStoreError.unsafeAliasRetirement(ids: ["legacy"])) {
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: [MusicDatabaseTrackID]()),
                repairs: [],
                retiredAliasIDs: ["legacy"],
                upserts: [],
                certificates: .invalidate(.membershipChanged)
            ))
        }

        #expect(try await store.getHistoricalTrack(byID: "legacy") != nil)
    }

    @Test("Conflicting recovery evidence rejects a grouped repair atomically")
    func rejectsConflictingEvidence() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "alias-a", name: "Song", artist: "Artist", album: "Album", originalArtist: "Artist A"
        ))
        context.insert(PersistedTrack(
            trackID: "alias-b", name: "Song", artist: "Artist", album: "Album", originalArtist: "Artist B"
        ))
        try context.save()
        let store = TrackDataStore(modelContainer: container)

        await #expect(throws: TrackStoreError.conflictingRepairEvidence(
            field: "originalArtist",
            sourceIDs: ["alias-a", "alias-b"]
        )) {
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: [testDatabaseID("canonical")]),
                repairs: [TrackMirrorRepair(
                    sourceIDs: ["alias-a", "alias-b"],
                    target: mirrorTrack(id: "canonical")
                )],
                upserts: [],
                certificates: .invalidate(.membershipChanged)
            ))
        }

        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<PersistedTrack>()) == 2)
    }

    @Test("Canonical recovery evidence participates in grouped repair validation")
    func rejectsCanonicalEvidenceConflict() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "canonical", appleScriptID: "canonical", name: "Song", artist: "Artist", album: "Album",
            originalArtist: "Canonical Artist"
        ))
        context.insert(PersistedTrack(
            trackID: "alias", name: "Song", artist: "Artist", album: "Album",
            originalArtist: "Alias Artist"
        ))
        try context.save()
        let store = TrackDataStore(modelContainer: container)

        await #expect(throws: TrackStoreError.conflictingRepairEvidence(
            field: "originalArtist",
            sourceIDs: ["alias", "canonical"]
        )) {
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: [testDatabaseID("canonical")]),
                repairs: [TrackMirrorRepair(
                    sourceIDs: ["alias"],
                    target: mirrorTrack(id: "canonical")
                )],
                upserts: [],
                certificates: .invalidate(.membershipChanged)
            ))
        }

        let verification = ModelContext(container)
        let tracks = try verification.fetch(FetchDescriptor<PersistedTrack>())
        #expect(Set(tracks.map(\.trackID)) == ["alias", "canonical"])
    }

    @Test("A partially missing alias group fails before merging")
    func rejectsPartialAliasGroup() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        context.insert(PersistedTrack(
            trackID: "canonical", appleScriptID: "canonical", name: "Song", artist: "Artist", album: "Album"
        ))
        context.insert(PersistedTrack(
            trackID: "alias-a", name: "Song", artist: "Artist", album: "Album", genreUpdated: true
        ))
        try context.save()
        let store = TrackDataStore(modelContainer: container)

        await #expect(throws: TrackStoreError.missingSource(id: "alias-b")) {
            try await store.commitMirror(MirrorCommit(
                baseRevision: .initial,
                inventoryChange: replacementInventory(for: [testDatabaseID("canonical")]),
                repairs: [TrackMirrorRepair(
                    sourceIDs: ["alias-a", "alias-b"],
                    target: mirrorTrack(id: "canonical")
                )],
                upserts: [],
                certificates: .invalidate(.membershipChanged)
            ))
        }

        let verification = ModelContext(container)
        #expect(try verification.fetchCount(FetchDescriptor<PersistedTrack>()) == 2)
        #expect(try verification.fetch(FetchDescriptor<PersistedTrack>()).contains { $0.trackID == "alias-a" })
    }

    @Test("Mirror update atomically combines rekey, upsert, and tombstone")
    func combinesMirrorChanges() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.seedMirror([
            mirrorTrack(id: "legacy"),
            mirrorTrack(id: "updated", name: "Old"),
            mirrorTrack(id: "deleted"),
        ])
        let context = ModelContext(container)
        let legacy = try #require(try context.fetch(FetchDescriptor<PersistedTrack>()).first {
            $0.trackID == "legacy"
        })
        legacy.appleScriptID = nil
        try context.save()
        let revision = try await store.loadMirrorSnapshot().revision

        try await store.commitMirror(MirrorCommit(
            baseRevision: revision,
            inventoryChange: replacementInventory(for: [
                testDatabaseID("inserted"),
                testDatabaseID("rekeyed"),
                testDatabaseID("updated"),
            ]),
            repairs: [TrackMirrorRepair(sourceIDs: ["legacy"], target: mirrorTrack(id: "rekeyed"))],
            upserts: [mirrorTrack(id: "updated", name: "New"), mirrorTrack(id: "inserted")],
            certificates: .invalidate(.membershipChanged)
        ))

        let tracks = try await store.loadMirrorSnapshot().presentTracks
        #expect(tracks.map(\.id).sorted() == ["inserted", "rekeyed", "updated"])
        #expect(tracks.first { $0.id == "updated" }?.name == "New")
    }

    @Test("A same-ID evidence-free alias canonicalizes in place during upsert")
    func canonicalizesSameIDAliasDuringUpsert() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let context = ModelContext(container)
        let alias = PersistedTrack(
            trackID: "canonical", name: "Legacy", artist: "Artist", album: "Album"
        )
        context.insert(alias)
        try context.save()
        let persistentID = alias.persistentModelID
        let store = TrackDataStore(modelContainer: container)

        try await store.commitMirror(MirrorCommit(
            baseRevision: .initial,
            inventoryChange: replacementInventory(for: [testDatabaseID("canonical")]),
            repairs: [],
            retiredAliasIDs: ["canonical"],
            upserts: [mirrorTrack(id: "canonical", name: "Current")],
            certificates: .invalidate(.membershipChanged)
        ))

        let verification = ModelContext(container)
        let tracks = try verification.fetch(FetchDescriptor<PersistedTrack>())
        let canonical = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(canonical.persistentModelID == persistentID)
        #expect(canonical.trackID == "canonical")
        #expect(canonical.appleScriptID == "canonical")
        #expect(canonical.name == "Current")
    }

    private func mirrorTrack(id: String, name: String = "Test Song") -> Track {
        Track(
            id: id,
            name: name,
            artist: "Test Artist",
            album: "Test Album",
            appleScriptID: id
        )
    }
}
