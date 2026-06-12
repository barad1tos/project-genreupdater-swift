import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — artist rename mappings")
struct UpdateCoordinatorArtistRenameTests {
    @Test("Artist rename mappings propose artist changes")
    func artistRenameMappingsProposeArtistChanges() async throws {
        let fixture = await makeCoordinator(
            mappings: ["DK Energetyk": "ДК Енергетик"]
        )

        let track = makeEditableTrack(artist: "dk energetyk")
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: true
        )

        let renameChange = changes.first { $0.changeType == .artistRename }
        #expect(renameChange?.oldValue == "dk energetyk")
        #expect(renameChange?.newValue == "ДК Енергетик")
        #expect(renameChange?.confidence == 100)
        #expect(renameChange?.source == "Artist Renamer")
    }

    @Test("Artist rename skips same normalized target")
    func artistRenameSkipsSameNormalizedTarget() async throws {
        let fixture = await makeCoordinator(
            mappings: ["TestArtist": "TESTARTIST"]
        )

        let track = makeEditableTrack(artist: "TestArtist")
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .artistRename })
    }

    @Test("Write mode applies artist rename to Music.app")
    func writeModeAppliesArtistRename() async throws {
        let fixture = await makeCoordinator(
            mappings: ["OldArtist": "NewArtist"]
        )

        let track = makeEditableTrack(artist: "OldArtist")
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: false
        )

        #expect(changes.contains { $0.changeType == .artistRename })
        let written = await fixture.bridge.writtenProperties
        #expect(written.contains { $0.property == "artist" && $0.value == "NewArtist" })
    }

    private func makeCoordinator(
        mappings: [String: String]
    ) async -> (coordinator: UpdateCoordinator, bridge: MockAppleScriptClient) {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            artistRenameMappings: mappings
        )

        let coordinator = UpdateCoordinator(
            apiOrchestrator: APIOrchestrator(
                musicBrainz: apiService,
                discogs: apiService,
                appleMusic: apiService
            ),
            scriptBridge: bridge,
            trackStore: MockTrackStore(),
            cache: MockCacheService(),
            undoCoordinator: UndoCoordinator(
                scriptBridge: bridge,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("UpdateCoordinatorArtistRenameTests-\(UUID().uuidString)")
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )

        return (coordinator, bridge)
    }

    private func makeEditableTrack(
        artist: String
    ) -> Track {
        Track(
            id: "T1",
            name: "Song",
            artist: artist,
            album: "Album",
            genre: "Rock",
            year: 2000,
            trackStatus: nil
        )
    }
}
