import Foundation
import Testing
@testable import Core
@testable import Services

struct CanonicalUndoMapper: TrackIDMapping {
    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        musicKitID
    }

    func trackWithAppleScriptMetadata(for track: Track) async -> Track? {
        var enrichedTrack = track
        enrichedTrack.appleScriptID = track.id
        enrichedTrack.trackStatus = TrackKind.subscription.rawValue
        return enrichedTrack
    }

    func hasMappingFor(musicKitID _: String) async -> Bool {
        true
    }
}

@Suite("Undo durable identity")
struct UndoIdentityTests {
    @Test("Revert writes the resolved database ID when mapper evidence is present")
    func revertUsesMappedDatabaseID() async throws {
        let bridge = MusicAppTestAccess()
        await bridge.setFetchedTracks([identityTrack()])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: FixedUndoTrackIDMapper(mapping: ["MK1": "AS1"]),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "MK1")
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.writtenProperties == [
            musicUpdate(databaseID: testDatabaseID("AS1"), property: .year, value: "1984"),
        ])
    }

    @Test("Relaunched undo resolves a canonical store row before an empty mapper")
    func relaunchedUndoUsesCanonicalStoreRow() async throws {
        let bridge = MusicAppTestAccess()
        let currentTrack = identityTrack()
        await bridge.setFetchedTracks([currentTrack])
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([currentTrack])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            stores: .init(tracks: trackStore),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "AS1")
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.writtenProperties.map(\.databaseID.rawValue) == ["AS1"])
        #expect(await coordinator.getHistory().isEmpty)
    }

    @Test("Relaunched undo rejects a recycled canonical database ID")
    func rejectsRecycledID() async throws {
        let bridge = MusicAppTestAccess()
        await bridge.setFetchedTracks([identityTrack(
            albumArtist: "Compilation Artist"
        )])
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([identityTrack()])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            stores: .init(tracks: trackStore),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "AS1")
        try await coordinator.recordChange(entry)

        await #expect(throws: UndoCoordinatorError.self) {
            try await coordinator.revertChange(entry)
        }

        #expect(await bridge.writtenProperties.isEmpty)
        #expect(await coordinator.getHistory() == [entry])
    }

    @Test("Batch undo reports a track that disappeared before dispatch")
    func batchReportsUnavailableTrack() async throws {
        let bridge = MusicAppTestAccess()
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: FixedUndoTrackIDMapper(mapping: ["MK1": "AS1"]),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "MK1")
        try await coordinator.recordChange(entry)

        await expectBatchFailure(
            coordinator,
            entry: entry,
            description: "Track is no longer available in Music.app. Refresh your library before retrying undo"
        )
        #expect(await bridge.writtenProperties.isEmpty)
    }

    @Test("Batch undo reports a recycled database ID before dispatch")
    func batchReportsChangedIdentity() async throws {
        let bridge = MusicAppTestAccess()
        await bridge.setFetchedTracks([identityTrack(albumArtist: "Compilation Artist")])
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([identityTrack()])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            stores: .init(tracks: trackStore),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "AS1")
        try await coordinator.recordChange(entry)

        await expectBatchFailure(
            coordinator,
            entry: entry,
            description: "Track metadata no longer matches this undo. Refresh your library before retrying undo"
        )
        #expect(await bridge.writtenProperties.isEmpty)
    }

    @Test("Legacy read-only history still fails closed without a mapping")
    func legacyHistoryWithoutMappingFailsClosed() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([identityTrack()])
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: MissingUndoTrackIDMapper(),
            stores: .init(tracks: trackStore),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "MK1")
        try await coordinator.recordChange(entry)

        await #expect(throws: UndoCoordinatorError.self) {
            try await coordinator.revertChange(entry)
        }

        #expect(await bridge.writtenProperties.isEmpty)
        #expect(await coordinator.getHistory() == [entry])
    }
}

private func expectBatchFailure(
    _ coordinator: UndoCoordinator,
    entry: ChangeLogEntry,
    description: String
) async {
    do {
        try await coordinator.revertBatch([entry])
        Issue.record("Expected partial revert failure")
    } catch let error as UndoCoordinatorError {
        guard case let .partialRevertFailure(succeeded, failed, descriptions) = error else {
            Issue.record("Expected partialRevertFailure, got \(error)")
            return
        }
        #expect(succeeded == 0)
        #expect(failed == 1)
        #expect(descriptions == [description])
        #expect(error.localizedDescription.contains(description))
        #expect(!error.localizedDescription.contains(entry.trackID))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private func identityTrack(
    name: String = "Track",
    artist: String = "Artist",
    album: String = "Album",
    albumArtist: String? = nil
) -> Track {
    Track(
        id: "AS1",
        name: name,
        artist: artist,
        album: album,
        year: 2000,
        trackStatus: TrackKind.subscription.rawValue,
        albumArtist: albumArtist,
        appleScriptID: "AS1"
    )
}

private func identityYearEntry(trackID: String) -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .yearUpdate,
        trackID: trackID,
        artist: "Artist",
        trackName: "Track",
        albumName: "Album"
    )
    entry.oldYear = 1984
    entry.newYear = 2000
    return entry
}

private func identityUndoDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("UndoIdentityTests-\(UUID().uuidString)")
}
