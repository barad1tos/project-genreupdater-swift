import CryptoKit
import Foundation
import GRDB
import Testing
@testable import Core
@testable import Services

@Suite("CachedLibrarySnapshotService")
struct LibrarySnapshotCacheTests {
    private struct LegacySnapshotTrack: Codable, Sendable {
        let id: String
        let name: String
        let artist: String
        let album: String
        let year: Int
        let releaseYear: Int
    }

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

    @Test("Refreshing a snapshot preserves the last force scan date")
    func refreshKeepsForceScanDate() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let firstSnapshotDate = Date(timeIntervalSince1970: 1_800_000_000)
        let forceScanDate = firstSnapshotDate.addingTimeInterval(-3 * 86400)
        let refreshDate = firstSnapshotDate.addingTimeInterval(3600)
        let dateProvider = SyncDateProvider(firstSnapshotDate)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: dateProvider.now
        )
        let firstTracks = [
            Track(id: "T1", name: "Song", artist: "Clutch", album: "Blast Tyrant"),
        ]
        let refreshedTracks = [
            Track(id: "T1", name: "Song", artist: "Clutch", album: "Blast Tyrant", genre: "Rock"),
        ]

        _ = try await service.saveSnapshot(firstTracks)
        var metadata = try #require(await service.getSnapshotMetadata())
        metadata.lastForceScanDate = forceScanDate
        try await service.updateSnapshotMetadata(metadata)
        dateProvider.set(refreshDate)

        _ = try await service.saveSnapshot(refreshedTracks)

        let refreshedMetadata = try #require(await service.getSnapshotMetadata())
        #expect(refreshedMetadata.lastForceScanDate == forceScanDate)
        #expect(refreshedMetadata.timestamp == refreshDate)
        #expect(try await service.loadSnapshot() == refreshedTracks)
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

    @Test("Unchanged library snapshot survives physical cache age")
    func preservesUnchangedSnapshot() async throws {
        let databaseQueue = try DatabaseQueue()
        let cache = GRDBCacheService(dbWriter: databaseQueue, defaultGenericTTL: 300)
        try await cache.initialize()
        var configuration = LibrarySnapshotConfig()
        configuration.maxAgeHours = 1
        let now = Date.now
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
        _ = try await service.saveSnapshot(tracks)
        try await databaseQueue.write { database in
            try database.execute(
                sql: "UPDATE generic_cache SET timestamp = ?",
                arguments: [now.addingTimeInterval(-7200)]
            )
        }

        let loaded = try await service.loadSnapshot()

        #expect(loaded == tracks)
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

    @Test("Legacy zero-year snapshot is rejected and rebuilt with canonical missing years")
    func rebuildsLegacyZeros() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let configuration = LibrarySnapshotConfig()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: configuration,
            currentDate: { now }
        )
        let legacyTracks = [
            LegacySnapshotTrack(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 0,
                releaseYear: 0
            ),
        ]
        let legacyHash = try snapshotHash(for: legacyTracks)
        let namespace = "library-snapshot:\(configuration.cacheFile)"
        await cache.setPersistent(key: "\(namespace):tracks", value: legacyTracks)
        try await service.updateSnapshotMetadata(LibraryCacheMetadata(
            trackCount: legacyTracks.count,
            snapshotHash: legacyHash,
            timestamp: now,
            libraryModificationDate: now
        ))

        #expect(try await service.loadSnapshot() == nil)

        _ = try await service.saveSnapshot([
            Track(
                id: "T1",
                name: "Angel",
                artist: "Massive Attack",
                album: "Mezzanine",
                year: 0,
                releaseYear: 0
            ),
        ])
        let rebuilt = try #require(try await service.loadSnapshot())

        #expect(rebuilt[0].year == nil)
        #expect(rebuilt[0].releaseYear == nil)
        #expect(await service.isSnapshotValid())
    }

    @Test("Refreshing a snapshot persists only tracks and metadata")
    func refreshStoresOnlySnapshotState() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        await cache.set(
            key: "library-snapshot:cache/library_snapshot.json:delta",
            value: "legacy delta",
            ttl: 3600
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: { now }
        )
        let firstSnapshot = [
            Track(id: "A", name: "Removed", artist: "Artist", album: "Album"),
            Track(id: "B", name: "Song", artist: "Artist", album: "Album", genre: "Rock", year: 2001),
            Track(id: "D", name: "Song", artist: "Artist", album: "Album", genre: "Jazz", year: 2005),
        ]
        let secondSnapshot = [
            Track(id: "B", name: "Song", artist: "Artist", album: "Album", genre: "Metal", year: 2001),
            Track(id: "C", name: "Added", artist: "Artist", album: "Album"),
            Track(id: "D", name: "Song", artist: "Artist", album: "Album", genre: "Jazz", year: 2006),
        ]

        _ = try await service.saveSnapshot(firstSnapshot)
        _ = try await service.saveSnapshot(secondSnapshot)

        let statistics = await cache.getCacheStatistics()
        #expect(try await service.loadSnapshot() == secondSnapshot)
        #expect(statistics.genericCacheCount == 2)
    }

    @Test("Clearing a snapshot preserves the force scan schedule through replacement")
    func clearPreservesForceScanDate() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        await cache.set(
            key: "library-snapshot:cache/library_snapshot.json:delta",
            value: "legacy delta",
            ttl: 3600
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let forceScanDate = now.addingTimeInterval(-3 * 86400)
        let service = CachedLibrarySnapshotService(
            cache: cache,
            configuration: LibrarySnapshotConfig(),
            currentDate: { now }
        )
        let firstSnapshot = [
            Track(id: "A", name: "Old", artist: "Artist", album: "Album"),
        ]
        let replacementSnapshot = [
            Track(id: "A", name: "New", artist: "Artist", album: "Album"),
        ]

        _ = try await service.saveSnapshot(firstSnapshot)
        var metadata = try #require(await service.getSnapshotMetadata())
        metadata.lastForceScanDate = forceScanDate
        try await service.updateSnapshotMetadata(metadata)

        await service.clearSnapshot()

        let statistics = await cache.getCacheStatistics()
        #expect(try await service.loadSnapshot() == nil)
        #expect(await service.getSnapshotMetadata()?.lastForceScanDate == forceScanDate)
        #expect(await !service.isSnapshotValid())
        #expect(statistics.genericCacheCount == 1)

        _ = try await service.saveSnapshot(replacementSnapshot)

        #expect(try await service.loadSnapshot() == replacementSnapshot)
        #expect(await service.getSnapshotMetadata()?.lastForceScanDate == forceScanDate)
    }

    private func snapshotHash(for tracks: [LegacySnapshotTrack]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tracks.sorted { $0.id < $1.id })
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
