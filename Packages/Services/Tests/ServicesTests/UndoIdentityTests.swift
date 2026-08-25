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
        let coordinator = UndoCoordinator(
            musicApp: bridge,
            idMapper: FixedUndoTrackIDMapper(mapping: ["MK1": "AS1"]),
            directory: identityUndoDirectory()
        )
        let entry = identityYearEntry(trackID: "MK1")
        try await coordinator.recordChange(entry)

        try await coordinator.revertChange(entry)

        #expect(await bridge.writtenProperties == [
            MusicTrackUpdate(databaseID: testDatabaseID("AS1"), property: .year, value: "1984"),
        ])
    }

    @Test("Relaunched undo resolves a canonical store row before an empty mapper")
    func relaunchedUndoUsesCanonicalStoreRow() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([Track(
            id: "AS1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: 2000,
            trackStatus: TrackKind.subscription.rawValue,
            appleScriptID: "AS1"
        )])
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

    @Test("Legacy read-only history still fails closed without a mapping")
    func legacyHistoryWithoutMappingFailsClosed() async throws {
        let bridge = MusicAppTestAccess()
        let trackStore = MockTrackStore()
        try await trackStore.seedMirror([Track(
            id: "AS1",
            name: "Track",
            artist: "Artist",
            album: "Album",
            year: 2000,
            trackStatus: TrackKind.subscription.rawValue,
            appleScriptID: "AS1"
        )])
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
