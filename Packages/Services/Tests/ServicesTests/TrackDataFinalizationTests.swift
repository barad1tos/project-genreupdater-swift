import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

extension TrackDataTests {
    @Test("Applied change enqueues derived effects once with its revision")
    func appliedChangeEnqueuesEffectsOnce() async throws {
        let store = try TrackDataStore.createInMemory()
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let change = appliedChange(type: .artistRename)

        let revision = try await store.commitAppliedChange(change)
        let firstPending = try await store.pendingMirrorEffects()
        let repeatedRevision = try await store.commitAppliedChange(change)

        let oldIdentity = AlbumIdentity(artist: "Test Artist", album: "Test Album")
        let newIdentity = AlbumIdentity(artist: "Canonical Artist", album: "Test Album")
        #expect(revision == MirrorRevision(value: 2))
        #expect(repeatedRevision == revision)
        #expect(firstPending.map(\.revision) == Array(repeating: revision, count: 6))
        #expect(firstPending.map(\.effect) == [
            .invalidateAlbumYear(oldIdentity),
            .invalidateAPIResults(oldIdentity),
            .invalidateAlbumYear(newIdentity),
            .invalidateAPIResults(newIdentity),
            .invalidateSnapshot,
            .refreshProjections,
        ])
        #expect(try await store.pendingMirrorEffects() == firstPending)
    }

    @Test("Distinct applied events with the same effect advance separately")
    func commitsDistinctEvents() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let firstChange = appliedChange(type: .genreUpdate)
        let secondChange = ChangeLogEntry(
            id: UUID(),
            timestamp: firstChange.timestamp.addingTimeInterval(1),
            changeType: firstChange.changeType,
            trackID: firstChange.trackID,
            artist: firstChange.artist,
            trackName: firstChange.trackName,
            albumName: firstChange.albumName,
            oldGenre: firstChange.oldGenre,
            newGenre: firstChange.newGenre
        )

        _ = try await store.commitAppliedChange(firstChange)
        _ = try await store.commitAppliedChange(secondChange)

        let snapshot = try await store.loadMirrorSnapshot()
        let context = ModelContext(container)
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(snapshot.revision == MirrorRevision(value: 3))
        #expect(Set(history.map(\.entryID)) == [firstChange.id, secondChange.id])
    }

    @Test("Observed no-op repairs canonical identity and advances revision")
    func repairsObservedIdentity() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let context = ModelContext(container)
        let persistedTrack = try #require(context.fetch(FetchDescriptor<PersistedTrack>()).first)
        persistedTrack.appleScriptID = "legacy-id"
        try context.save()
        let change = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            changeType: .genreUpdate,
            trackID: "T001",
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album",
            oldGenre: "Rock",
            newGenre: "Rock"
        )

        let revision = try await store.commitObservedChange(change)

        let storedTrack = try #require(try await store.getTrack(byID: "T001"))
        let snapshot = try await store.loadMirrorSnapshot()
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(revision == MirrorRevision(value: 2))
        #expect(snapshot.contentRevision == revision)
        #expect(storedTrack.appleScriptID == "T001")
        #expect(storedTrack.yearBeforeMGU == nil)
        #expect(history.isEmpty)
    }

    @Test("Observed no-op retry does not advance an already finalized mirror")
    func observedRetryIsIdempotent() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let change = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            changeType: .genreUpdate,
            trackID: "T001",
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album",
            oldGenre: "Metal",
            newGenre: "Metal"
        )

        let firstRevision = try await store.commitObservedChange(change)
        let secondRevision = try await store.commitObservedChange(change)

        let snapshot = try await store.loadMirrorSnapshot()
        let history = try ModelContext(container).fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(firstRevision == MirrorRevision(value: 2))
        #expect(secondRevision == firstRevision)
        #expect(snapshot.revision == firstRevision)
        #expect(snapshot.presentTracks.first?.genre == "Metal")
        #expect(history.isEmpty)
    }

    @Test("Existing history repairs an unfinished mirror finalization once")
    func repairsHistoricSplitFinalization() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let change = ChangeLogEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            changeType: .yearUpdate,
            trackID: "T001",
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album",
            oldYear: 2020,
            newYear: 2024
        )
        let context = ModelContext(container)
        context.insert(PersistedChangeLogEntry(from: change))
        try context.save()

        _ = try await store.commitAppliedChange(change)
        _ = try await store.commitAppliedChange(change)

        let snapshot = try await store.loadMirrorSnapshot()
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.presentTracks.first?.year == 2024)
        #expect(history.map(\.entryID) == [change.id])
    }

    @Test("Missing history repair advances artist membership with the mirror revision")
    func repairsSplitArtistMembership() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let change = appliedChange(type: .artistRename)
        let context = ModelContext(container)
        let persistedTrack = try #require(context.fetch(FetchDescriptor<PersistedTrack>()).first)
        persistedTrack.artist = "Canonical Artist"
        persistedTrack.originalArtist = "Test Artist"
        persistedTrack.processedDate = change.timestamp
        try context.save()

        _ = try await store.commitAppliedChange(change)

        let snapshot = try await store.loadMirrorSnapshot()
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        let member = try #require(context.fetch(FetchDescriptor<PersistedLibraryMember>()).first)
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(history.map(\.entryID) == [change.id])
        #expect(member.artist == "Canonical Artist")
        #expect(member.identityRevisionValue == 2)
    }

    @Test("Recovery canonicalizes same-event legacy history atomically")
    func canonicalizesLegacyHistory() async throws {
        let container = try ModelContainerFactory.createInMemory()
        let store = TrackDataStore(modelContainer: container)
        try await store.initialize()
        try await store.seedMirror([sampleTrack()])
        let changeID = UUID()
        let runID = UUID()
        var legacy = ChangeLogEntry(
            id: changeID,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            changeType: .genreUpdate,
            trackID: "music-kit-1",
            artist: "Test Artist",
            trackName: "Test Song",
            albumName: "Test Album",
            oldGenre: "Rock",
            newGenre: "Metal"
        )
        legacy.runID = runID
        var canonical = ChangeLogEntry(
            id: changeID,
            timestamp: legacy.timestamp,
            changeType: legacy.changeType,
            trackID: "T001",
            artist: legacy.artist,
            trackName: legacy.trackName,
            albumName: legacy.albumName,
            oldGenre: legacy.oldGenre,
            newGenre: legacy.newGenre
        )
        canonical.runID = runID
        let context = ModelContext(container)
        context.insert(PersistedChangeLogEntry(from: legacy))
        try context.save()

        _ = try await store.commitAppliedChange(canonical)
        _ = try await store.commitAppliedChange(canonical)

        let snapshot = try await store.loadMirrorSnapshot()
        let history = try context.fetch(FetchDescriptor<PersistedChangeLogEntry>())
        #expect(snapshot.revision == MirrorRevision(value: 2))
        #expect(snapshot.presentTracks.first?.genre == "Metal")
        #expect(history.map(\.entryID) == [changeID])
        #expect(history.map(\.trackID) == ["T001"])
    }
}
