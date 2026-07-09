import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — artist rename mappings")
struct ArtistRenameTests {
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

    @Test("Artist rename write invalidates old original and new cache identities")
    func artistRenameWriteInvalidatesAllCacheIdentities() async throws {
        let fixture = await makeCoordinator(
            mappings: ["OldArtist": "NewArtist"]
        )
        let cacheTargets = ["OldArtist", "OriginalArtist", "NewArtist"]
        for artist in cacheTargets {
            await seedCacheIdentity(
                artist: artist,
                album: "Album",
                cache: fixture.cache
            )
        }

        let track = makeEditableTrack(
            artist: "OldArtist",
            originalArtist: "OriginalArtist"
        )
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: false
        )

        #expect(changes.contains { $0.changeType == .artistRename })
        for artist in cacheTargets {
            let albumYear = await fixture.cache.getAlbumYear(artist: artist, album: "Album")
            let apiResult = await fixture.cache.getCachedAPIResult(
                artist: artist,
                album: "Album",
                source: "musicbrainz"
            )
            #expect(albumYear == nil)
            #expect(apiResult == nil)
        }
    }

    @Test("Scoped write mode applies allowed artist rename")
    func scopedWriteModeAppliesAllowedArtistRename() async throws {
        let fixture = await makeCoordinator(
            mappings: ["OldArtist": "NewArtist"],
            testArtists: ["OldArtist"]
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
        mappings: [String: String],
        testArtists: [String] = []
    ) async -> (coordinator: UpdateCoordinator, bridge: MockAppleScriptClient, cache: MockCacheService) {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let cache = MockCacheService()
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            artistRenameMappings: mappings,
            testArtists: testArtists
        )

        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ArtistRenameTests-\(UUID().uuidString)")
                )
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )

        return (coordinator, bridge, cache)
    }

    private func makeEditableTrack(
        artist: String,
        originalArtist: String? = nil
    ) -> Track {
        Track(
            id: "T1",
            name: "Song",
            artist: artist,
            album: "Album",
            genre: "Rock",
            year: 2000,
            trackStatus: nil,
            originalArtist: originalArtist
        )
    }

    private func seedCacheIdentity(
        artist: String,
        album: String,
        cache: MockCacheService
    ) async {
        await cache.storeAlbumYear(
            artist: artist,
            album: album,
            year: 2001,
            confidence: 95
        )
        await cache.setCachedAPIResult(
            CachedAPIResult(
                artist: artist,
                album: album,
                year: 2001,
                source: "musicbrainz",
                timestamp: Date(),
                ttl: nil
            )
        )
    }
}
