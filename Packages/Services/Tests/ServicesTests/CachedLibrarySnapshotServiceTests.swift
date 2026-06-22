import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("CachedLibrarySnapshotService")
struct CachedLibrarySnapshotServiceTests {
    @Test("Save and load snapshot through cache service")
    func saveAndLoadSnapshot() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.maxAgeHours = 24
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now }
        )
        let tracks = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album"),
        ]

        let hash = try await service.saveSnapshot(tracks)
        let loaded = try await service.loadSnapshot()
        let metadata = await service.getSnapshotMetadata()

        #expect(!hash.isEmpty)
        #expect(loaded == tracks)
        #expect(metadata?.trackCount == 1)
        #expect(metadata?.snapshotHash == hash)
        #expect(await service.isSnapshotValid())
    }

    @Test("Snapshot validity follows configured max age")
    func snapshotValidityUsesMaxAge() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.maxAgeHours = 1
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now }
        )
        let tracks = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album"),
        ]
        let hash = try await service.saveSnapshot(tracks)
        let metadata = LibraryCacheMetadata(
            trackCount: tracks.count,
            snapshotHash: hash,
            timestamp: now.addingTimeInterval(-7200),
            libraryModificationDate: now.addingTimeInterval(-7200)
        )

        try await service.updateSnapshotMetadata(metadata)

        #expect(await !(service.isSnapshotValid()))
    }

    @Test("Snapshot remains valid past max age when library file is unchanged")
    func snapshotValidityIgnoresAgeWhenLibraryUnchanged() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.maxAgeHours = 1
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let libraryModificationDate = now.addingTimeInterval(-86400)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now },
            libraryModificationDateProvider: { libraryModificationDate }
        )
        let tracks = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album"),
        ]
        let hash = try await service.saveSnapshot(tracks)
        let metadata = LibraryCacheMetadata(
            trackCount: tracks.count,
            snapshotHash: hash,
            timestamp: now.addingTimeInterval(-7200),
            libraryModificationDate: libraryModificationDate
        )

        try await service.updateSnapshotMetadata(metadata)

        #expect(await service.isSnapshotValid())
    }

    @Test("Snapshot expires by age when library file changed")
    func snapshotValidityUsesMaxAgeWhenLibraryChanged() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.maxAgeHours = 1
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let currentLibraryModificationDate = now
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now },
            libraryModificationDateProvider: { currentLibraryModificationDate }
        )
        let tracks = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album"),
        ]
        let hash = try await service.saveSnapshot(tracks)
        let metadata = LibraryCacheMetadata(
            trackCount: tracks.count,
            snapshotHash: hash,
            timestamp: now.addingTimeInterval(-7200),
            libraryModificationDate: now.addingTimeInterval(-7200)
        )

        try await service.updateSnapshotMetadata(metadata)

        #expect(await !(service.isSnapshotValid()))
    }

    @Test("Snapshot validity requires cached tracks")
    func snapshotValidityRequiresCachedTracks() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: { now }
        )
        let metadata = LibraryCacheMetadata(
            trackCount: 1,
            snapshotHash: "missing",
            timestamp: now,
            libraryModificationDate: now
        )

        try await service.updateSnapshotMetadata(metadata)

        #expect(await !(service.isSnapshotValid()))
    }

    @Test("Snapshot validity rejects hash mismatch")
    func snapshotValidityRejectsHashMismatch() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: { now }
        )
        let tracks = [
            Track(id: "1", name: "Song", artist: "Artist", album: "Album"),
        ]
        _ = try await service.saveSnapshot(tracks)
        let metadata = LibraryCacheMetadata(
            trackCount: tracks.count,
            snapshotHash: "different",
            timestamp: now,
            libraryModificationDate: now
        )

        try await service.updateSnapshotMetadata(metadata)

        #expect(await !(service.isSnapshotValid()))
    }

    @Test("Second snapshot records delta when enabled")
    func secondSnapshotRecordsDelta() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.deltaEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now }
        )
        let firstSnapshot = [
            Track(id: "A", name: "Removed", artist: "Artist", album: "Album"),
            Track(id: "B", name: "Old", artist: "Artist", album: "Album"),
        ]
        let secondSnapshot = [
            Track(id: "B", name: "New", artist: "Artist", album: "Album"),
            Track(id: "C", name: "Added", artist: "Artist", album: "Album"),
        ]

        _ = try await service.saveSnapshot(firstSnapshot)
        _ = try await service.saveSnapshot(secondSnapshot)

        let delta = await service.loadDelta()
        #expect(delta?.addedIDs == ["C"])
        #expect(delta?.removedIDs == ["A"])
        #expect(delta?.modifiedIDs == ["B"])
    }

    @Test("Second snapshot ignores newly populated track status")
    func secondSnapshotIgnoresNewlyPopulatedTrackStatus() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.deltaEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now }
        )
        let firstSnapshot = [
            Track(id: "A", name: "Song", artist: "Artist", album: "Album", genre: "Rock", year: 2001),
        ]
        let secondSnapshot = [
            Track(
                id: "A",
                name: "Song",
                artist: "Artist",
                album: "Album",
                genre: "Rock",
                year: 2001,
                trackStatus: "matched"
            ),
        ]

        _ = try await service.saveSnapshot(firstSnapshot)
        _ = try await service.saveSnapshot(secondSnapshot)

        let delta = await service.loadDelta()
        #expect(delta?.modifiedIDs.isEmpty == true)
    }

    @Test("Clear snapshot removes tracks metadata and delta")
    func clearSnapshotRemovesTracksMetadataAndDelta() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.deltaEnabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now }
        )
        let firstSnapshot = [
            Track(id: "A", name: "Old", artist: "Artist", album: "Album"),
        ]
        let secondSnapshot = [
            Track(id: "A", name: "New", artist: "Artist", album: "Album"),
        ]

        _ = try await service.saveSnapshot(firstSnapshot)
        _ = try await service.saveSnapshot(secondSnapshot)
        await service.clearSnapshot()

        let loaded = try await service.loadSnapshot()
        let metadata = await service.getSnapshotMetadata()
        let delta = await service.loadDelta()
        #expect(loaded == nil)
        #expect(metadata == nil)
        #expect(delta == nil)
        #expect(await !service.isSnapshotValid())
    }
}
