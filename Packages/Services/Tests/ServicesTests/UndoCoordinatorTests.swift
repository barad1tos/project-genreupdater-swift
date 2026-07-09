import Foundation
import SwiftData
import Testing
@testable import Core
@testable import Services

// MARK: - Helpers

private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("UndoCoordinatorTests-\(UUID().uuidString)")
}

private func makeGenreEntry(
    trackID: String = "T1",
    oldGenre: String = "Rock",
    newGenre: String = "Pop"
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .genreUpdate,
        trackID: trackID,
        artist: "Artist",
        trackName: "Track",
        albumName: "Album"
    )
    entry.oldGenre = oldGenre
    entry.newGenre = newGenre
    return entry
}

private func makeYearEntry(
    trackID: String = "T1",
    artist: String = "Artist",
    album: String = "Album",
    oldYear: Int = 1984,
    newYear: Int = 2000
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .yearUpdate,
        trackID: trackID,
        artist: artist,
        trackName: "Track",
        albumName: album
    )
    entry.oldYear = oldYear
    entry.newYear = newYear
    return entry
}

private func makeArtistRenameEntry(
    trackID: String = "T1",
    oldArtist: String = "Old Artist",
    newArtist: String = "New Artist"
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .artistRename,
        trackID: trackID,
        artist: newArtist,
        trackName: "Track",
        albumName: "Album"
    )
    entry.oldArtist = oldArtist
    entry.newArtist = newArtist
    return entry
}

private func makeAlbumCleaningEntry(
    trackID: String = "T1",
    artist: String = "Artist",
    oldAlbum: String = "Album (Remastered)",
    newAlbum: String = "Album"
) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .albumCleaning,
        trackID: trackID,
        artist: artist,
        trackName: "Track",
        albumName: oldAlbum
    )
    entry.oldAlbumName = oldAlbum
    entry.newAlbumName = newAlbum
    return entry
}

struct MissingUndoTrackIDMapper: TrackIDMapping {
    func appleScriptID(forMusicKitID _: String) async -> String? {
        nil
    }

    func trackWithAppleScriptMetadata(for _: Track) async -> Track? {
        nil
    }

    func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
        await Task.yield()
    }

    func hasMappingFor(musicKitID _: String) async -> Bool {
        false
    }
}

struct FixedUndoTrackIDMapper: TrackIDMapping {
    let mapping: [String: String]

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        mapping[musicKitID]
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        musicKitTrack
    }

    func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
        await Task.yield()
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        mapping[musicKitID] != nil
    }
}

struct MetadataUndoTrackIDMapper: TrackIDMapping {
    let mapping: [String: String]
    let metadata: [String: Track]

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        mapping[musicKitID]
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        metadata[musicKitTrack.id] ?? musicKitTrack
    }

    func refreshMapping(musicKitTracks _: [Track], appleScriptTracks _: [Track]) async {
        await Task.yield()
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        mapping[musicKitID] != nil
    }
}

struct RawTrackIDWriteError: LocalizedError {
    let trackID: String

    var errorDescription: String? {
        "Track=\(trackID), AppleScript write failed"
    }
}

// MARK: - Tests

@Suite("UndoCoordinator — record and revert changes")
struct UndoCoordinatorTests {
    @Test("Record and get history")
    func recordAndGetHistory() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entry1 = makeGenreEntry(trackID: "T1")
        let entry2 = makeYearEntry(trackID: "T2")

        await coordinator.recordChange(entry1)
        await coordinator.recordChange(entry2)

        let history = await coordinator.getHistory()
        #expect(history.count == 2)
    }

    @Test("Revert single genre change writes old value")
    func revertSingleGenre() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entry = makeGenreEntry(trackID: "T1", oldGenre: "Rock", newGenre: "Pop")
        await coordinator.recordChange(entry)
        try await coordinator.revertChange(entry)

        let written = await bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].trackID == "T1")
        #expect(written[0].property == "genre")
        #expect(written[0].value == "Rock")

        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }

    @Test("Revert single year change writes old value")
    func revertSingleYear() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entry = makeYearEntry(trackID: "T1", oldYear: 1984)
        await coordinator.recordChange(entry)
        try await coordinator.revertChange(entry)

        let written = await bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].property == "year")
        #expect(written[0].value == "1984")
    }

    @Test("Revert invalidates album API and snapshot caches")
    func revertInvalidatesAlbumAPIAndSnapshotCaches() async throws {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let snapshotService = MockUndoLibrarySnapshotService()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            cache: cache,
            librarySnapshotService: snapshotService,
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)

        await cache.storeAlbumYear(artist: entry.artist, album: entry.albumName, year: 2000, confidence: 100)
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: entry.artist,
            album: entry.albumName,
            year: 2000,
            source: "discogs",
            timestamp: .now,
            ttl: nil
        ))

        try await coordinator.revertChange(entry)

        #expect(await cache.getAlbumYear(artist: entry.artist, album: entry.albumName) == nil)
        #expect(await cache.getCachedAPIResult(artist: entry.artist, album: entry.albumName, source: "discogs") == nil)
        #expect(await snapshotService.wasCleared())
    }

    @Test("Revert invalidates enriched album artist cache aliases")
    func revertInvalidatesEnrichedAlbumArtistCacheAliases() async throws {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let snapshotService = MockUndoLibrarySnapshotService()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: MetadataUndoTrackIDMapper(
                mapping: ["MK1": "AS1"],
                metadata: [
                    "MK1": Track(
                        id: "MK1",
                        name: "Karmacoma",
                        artist: "Tricky",
                        album: "Protection",
                        year: 2000,
                        albumArtist: "Massive Attack"
                    ),
                ]
            ),
            cache: cache,
            librarySnapshotService: snapshotService,
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(
            trackID: "MK1",
            artist: "Tricky",
            album: "Protection",
            oldYear: 1994
        )

        await cache.storeAlbumYear(artist: "Massive Attack", album: "Protection", year: 2000, confidence: 100)
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Massive Attack",
            album: "Protection",
            year: 2000,
            source: "discogs",
            timestamp: .now,
            ttl: nil
        ))

        try await coordinator.revertChange(entry)

        #expect(await cache.getAlbumYear(artist: "Massive Attack", album: "Protection") == nil)
        #expect(await cache.getCachedAPIResult(artist: "Massive Attack", album: "Protection", source: "discogs") == nil)
        #expect(await snapshotService.wasCleared())
    }

    @Test("Revert invalidates cleaned album cache aliases")
    func revertInvalidatesCleanedAlbumCacheAliases() async throws {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            cache: cache,
            cleaning: CleaningConfig(),
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(
            trackID: "MK1",
            artist: "Massive Attack",
            album: "Mezzanine Remastered",
            oldYear: 1998
        )

        await cache.storeAlbumYear(artist: "Massive Attack", album: "Mezzanine", year: 2019, confidence: 100)
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: "Massive Attack",
            album: "Mezzanine",
            year: 2019,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        ))

        try await coordinator.revertChange(entry)

        #expect(await cache.getAlbumYear(artist: "Massive Attack", album: "Mezzanine") == nil)
        #expect(await cache
            .getCachedAPIResult(artist: "Massive Attack", album: "Mezzanine", source: "musicbrainz") == nil)
    }

    @Test("Album cleaning revert invalidates current and restored album caches")
    func albumCleaningRevertInvalidatesCurrentAndRestoredAlbumCaches() async throws {
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let snapshotService = MockUndoLibrarySnapshotService()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            cache: cache,
            librarySnapshotService: snapshotService,
            directory: makeTempDirectory()
        )
        let entry = makeAlbumCleaningEntry(
            artist: "Massive Attack",
            oldAlbum: "Mezzanine (Remastered)",
            newAlbum: "Mezzanine"
        )

        await cache.storeAlbumYear(artist: entry.artist, album: "Mezzanine", year: 1998, confidence: 100)
        await cache.storeAlbumYear(artist: entry.artist, album: "Mezzanine (Remastered)", year: 1998, confidence: 100)
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: entry.artist,
            album: "Mezzanine",
            year: 1998,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        ))
        await cache.setCachedAPIResult(CachedAPIResult(
            artist: entry.artist,
            album: "Mezzanine (Remastered)",
            year: 1998,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        ))

        try await coordinator.revertChange(entry)

        #expect(await cache.getAlbumYear(artist: entry.artist, album: "Mezzanine") == nil)
        #expect(await cache.getAlbumYear(artist: entry.artist, album: "Mezzanine (Remastered)") == nil)
        #expect(await cache.getCachedAPIResult(artist: entry.artist, album: "Mezzanine", source: "musicbrainz") == nil)
        #expect(
            await cache.getCachedAPIResult(
                artist: entry.artist,
                album: "Mezzanine (Remastered)",
                source: "musicbrainz"
            ) == nil
        )
        #expect(await snapshotService.wasCleared())
    }

    @Test("Revert writes resolved AppleScript ID when mapper is present")
    func revertWritesResolvedAppleScriptID() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: FixedUndoTrackIDMapper(mapping: ["MK1": "AS1"]),
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        let written = await bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].trackID == "AS1")
        #expect(written[0].property == "year")
        #expect(written[0].value == "1984")
    }

    @Test("Revert refuses missing AppleScript ID mapping")
    func revertRefusesMissingAppleScriptIDMapping() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        do {
            try await coordinator.revertChange(entry)
            Issue.record("Expected missing AppleScript ID error")
        } catch let error as UndoCoordinatorError {
            if case let .missingAppleScriptID(trackID) = error {
                #expect(trackID == "MK1")
                #expect(error.localizedDescription.contains("AppleScript ID mapping"))
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected missingAppleScriptID, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)

        let history = await coordinator.getHistory()
        #expect(history.count == 1)
    }

    @Test("Revert refuses prerelease AppleScript metadata")
    func revertRefusesPrereleaseAppleScriptMetadata() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: MetadataUndoTrackIDMapper(
                mapping: ["MK1": "AS1"],
                metadata: [
                    "MK1": Track(
                        id: "MK1",
                        name: "Track",
                        artist: "Artist",
                        album: "Album",
                        year: 2000,
                        trackStatus: "prerelease"
                    ),
                ]
            ),
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        await #expect(throws: UndoCoordinatorError.self) {
            try await coordinator.revertChange(entry)
        }

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Batch revert missing AppleScript ID failure is public-safe")
    func batchRevertMissingAppleScriptIDFailureIsPublicSafe() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            directory: makeTempDirectory()
        )
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        do {
            try await coordinator.revertBatch([entry])
            Issue.record("Expected partial revert failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(succeeded, failed, descriptions) = error {
                #expect(succeeded == 0)
                #expect(failed == 1)
                #expect(descriptions.first?.contains("AppleScript ID mapping") == true)
                #expect(descriptions.first?.contains("MK1") == false)
                #expect(error.localizedDescription.contains("AppleScript ID mapping"))
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let written = await bridge.writtenProperties
        #expect(written.isEmpty)
    }

    @Test("Batch revert write failure description is public-safe")
    func batchRevertWriteFailureDescriptionIsPublicSafe() async {
        let bridge = MockAppleScriptClient()
        await bridge.setCustomWriteError(RawTrackIDWriteError(trackID: "MK1"))
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        do {
            try await coordinator.revertBatch([entry])
            Issue.record("Expected partial revert failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(succeeded, failed, descriptions) = error {
                #expect(succeeded == 0)
                #expect(failed == 1)
                #expect(descriptions.first == "AppleScript write failed")
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Batch revert domain failure description is public-safe")
    func batchRevertDomainFailureDescriptionIsPublicSafe() async {
        let bridge = MockAppleScriptClient()
        await bridge.setCustomWriteError(UndoCoordinatorError.revertFailed(trackID: "MK1", reason: "boom"))
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        do {
            try await coordinator.revertBatch([entry])
            Issue.record("Expected partial revert failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(succeeded, failed, descriptions) = error {
                #expect(succeeded == 0)
                #expect(failed == 1)
                #expect(descriptions.first == "Failed to revert track")
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Batch revert preserves safe AppleScript setup failure description")
    func batchRevertPreservesSafeAppleScriptSetupFailureDescription() async {
        let bridge = MockAppleScriptClient()
        await bridge.setCustomWriteError(
            AppleScriptBridgeError.scriptNotFound(
                name: "update_property",
                searchPath: FileManager.default.temporaryDirectory
            )
        )
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())
        let entry = makeYearEntry(trackID: "MK1", oldYear: 1984)
        await coordinator.recordChange(entry)

        do {
            try await coordinator.revertBatch([entry])
            Issue.record("Expected partial revert failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(succeeded, failed, descriptions) = error {
                #expect(succeeded == 0)
                #expect(failed == 1)
                #expect(descriptions.first?.contains("update_property.scpt") == true)
                #expect(!error.localizedDescription.contains("MK1"))
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Revert single artist rename writes old artist")
    func revertSingleArtistRename() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entry = makeArtistRenameEntry(trackID: "T1", oldArtist: "Old Artist", newArtist: "New Artist")
        await coordinator.recordChange(entry)
        try await coordinator.revertChange(entry)

        let written = await bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].trackID == "T1")
        #expect(written[0].property == "artist")
        #expect(written[0].value == "Old Artist")
    }

    @Test("Batch revert processes all entries")
    func batchRevert() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entries = [
            makeGenreEntry(trackID: "T1"),
            makeYearEntry(trackID: "T2"),
        ]
        await coordinator.recordChanges(entries)
        try await coordinator.revertBatch(entries)

        let written = await bridge.writtenProperties
        #expect(written.count == 2)
    }

    @Test("Batch revert on empty list throws noChangesToRevert")
    func batchRevertEmpty() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        await #expect(throws: UndoCoordinatorError.self) {
            try await coordinator.revertBatch([])
        }
    }

    @Test("Partial revert failure reports failed counts")
    func partialRevertFailure() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entry1 = makeGenreEntry(trackID: "T1")
        let entry2 = makeYearEntry(trackID: "T2")
        await coordinator.recordChanges([entry1, entry2])

        // Make bridge fail on all writes
        await bridge.setThrowMode(true)
        do {
            try await coordinator.revertBatch([entry1, entry2])
            Issue.record("Expected partial failure")
        } catch let error as UndoCoordinatorError {
            if case let .partialRevertFailure(_, failed, _) = error {
                #expect(failed == 2)
            } else {
                Issue.record("Expected partialRevertFailure, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Clear history removes all entries")
    func clearHistory() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        await coordinator.recordChange(makeGenreEntry())
        await coordinator.recordChange(makeYearEntry())
        await coordinator.clearHistory()

        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }

    @Test("Selective revert only reverts specified entries")
    func selectiveRevert() async throws {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        let entry1 = makeGenreEntry(trackID: "T1")
        let entry2 = makeYearEntry(trackID: "T2")
        let entry3 = makeGenreEntry(trackID: "T3", oldGenre: "Jazz", newGenre: "Blues")
        await coordinator.recordChanges([entry1, entry2, entry3])

        // Only revert entry2
        try await coordinator.revertSelective([entry2])

        let written = await bridge.writtenProperties
        #expect(written.count == 1)
        #expect(written[0].trackID == "T2")
        #expect(written[0].property == "year")

        // entry2 removed from history, entries 1 and 3 remain
        let history = await coordinator.getHistory()
        #expect(history.count == 2)
    }

    @Test("History limit returns only N most recent entries")
    func historyLimit() async {
        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: makeTempDirectory())

        for i in 0 ..< 5 {
            await coordinator.recordChange(makeGenreEntry(trackID: "T\(i)"))
        }

        let limited = await coordinator.getHistory(limit: 2)
        #expect(limited.count == 2)
    }
}

// MARK: - Persistence Tests

@Suite("UndoCoordinator — SwiftData persistence")
struct UndoCoordinatorPersistenceTests {
    @Test("History survives round-trip through new coordinator instance")
    func persistenceRoundTrip() async throws {
        let directory = makeTempDirectory()
        let bridge = MockAppleScriptClient()
        let container = try ModelContainerFactory.createInMemory()
        let store1 = ChangeLogDataStore(modelContainer: container)

        let coordinator1 = UndoCoordinator(scriptBridge: bridge, changeLogStore: store1, directory: directory)
        await coordinator1.recordChange(makeGenreEntry(trackID: "T1"))
        await coordinator1.recordChange(makeYearEntry(trackID: "T2"))

        let store2 = ChangeLogDataStore(modelContainer: container)
        let coordinator2 = UndoCoordinator(scriptBridge: bridge, changeLogStore: store2, directory: directory)
        let history = await coordinator2.getHistory()
        #expect(history.count == 2)

        let trackIDs = Set(history.map(\.trackID))
        #expect(trackIDs == ["T1", "T2"])
    }

    @Test("Corrupt history file loads empty history")
    func corruptFileReturnsEmpty() async {
        let directory = makeTempDirectory()
        let historyURL = directory.appendingPathComponent("undo-history.json")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not valid json".utf8).write(to: historyURL)

        let bridge = MockAppleScriptClient()
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: directory)
        let history = await coordinator.getHistory()
        #expect(history.isEmpty)
    }

    @Test("Legacy JSON imports into SwiftData when store is empty")
    func legacyJSONImportsIntoSwiftData() async throws {
        let directory = makeTempDirectory()
        let historyURL = directory.appendingPathComponent("undo-history.json")
        let bridge = MockAppleScriptClient()
        let container = try ModelContainerFactory.createInMemory()
        let store = ChangeLogDataStore(modelContainer: container)
        let legacyEntries = [
            makeGenreEntry(trackID: "T1"),
            makeYearEntry(trackID: "T2"),
        ]

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyEntries).write(to: historyURL, options: .atomic)

        let coordinator = UndoCoordinator(scriptBridge: bridge, changeLogStore: store, directory: directory)
        let history = await coordinator.getHistory()
        let stored = try await store.loadAll()

        #expect(history.count == 2)
        #expect(stored.count == 2)
    }

    @Test("clearHistory deletes the legacy history file")
    func clearHistoryDeletesLegacyFile() async {
        let directory = makeTempDirectory()
        let historyURL = directory.appendingPathComponent("undo-history.json")
        let bridge = MockAppleScriptClient()

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("[]".utf8).write(to: historyURL)
        let coordinator = UndoCoordinator(scriptBridge: bridge, directory: directory)
        #expect(FileManager.default.fileExists(atPath: historyURL.path))

        await coordinator.clearHistory()
        #expect(!FileManager.default.fileExists(atPath: historyURL.path))
    }
}
