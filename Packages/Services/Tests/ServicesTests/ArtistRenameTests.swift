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

    @Test("Artist rename preview keeps a matching album artist coupled")
    func artistRenamePreviewKeepsMatchingAlbumArtistCoupled() async throws {
        let fixture = await makeCoordinator(
            mappings: ["DK Energetyk": "ДК Енергетик"]
        )

        let track = makeEditableTrack(
            artist: "DK Energetyk",
            albumArtist: "DK Energetyk"
        )
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: true
        )

        let renameChange = changes.first { $0.changeType == .artistRename }
        #expect(renameChange?.track.albumArtist == "ДК Енергетик")
        #expect(renameChange?.albumArtistChange == AlbumArtistChange(
            oldValue: "DK Energetyk",
            newValue: "ДК Енергетик"
        ))
    }

    @Test(
        "Artist rename preserves absent and distinct album artists",
        arguments: [nil, "Various Artists"] as [String?]
    )
    func artistRenamePreservesUncoupledAlbumArtist(albumArtist: String?) async throws {
        let fixture = await makeCoordinator(
            mappings: ["DK Energetyk": "ДК Енергетик"]
        )
        let track = makeEditableTrack(
            artist: "DK Energetyk",
            albumArtist: albumArtist
        )

        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: true
        )

        let renameChange = changes.first { $0.changeType == .artistRename }
        #expect(renameChange?.track.albumArtist == albumArtist)
        #expect(renameChange?.albumArtistChange == nil)
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
        #expect(written.contains { $0.property == .artist && $0.value == "NewArtist" })
    }

    @Test("Write mode updates matching artist fields as one verified operation")
    func writeModeUpdatesMatchingArtistFieldsTogether() async throws {
        let fixture = await makeCoordinator(
            mappings: ["OldArtist": "NewArtist"]
        )
        let track = makeEditableTrack(
            artist: "OldArtist",
            albumArtist: "OldArtist"
        )
        await fixture.bridge.setFetchedTracks([track])

        _ = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            dryRun: false
        )

        let batches = await fixture.bridge.batchUpdates
        #expect(batches == [[
            musicUpdate(databaseID: testDatabaseID("T1"), property: .artist, value: "NewArtist"),
            musicUpdate(databaseID: testDatabaseID("T1"), property: .albumArtist, value: "NewArtist"),
        ]])
    }

    @Test("Artist rename write invalidates old original and new cache identities")
    func artistRenameWriteInvalidatesAllCacheIdentities() async throws {
        let track = makeEditableTrack(
            artist: "OldArtist",
            originalArtist: "OriginalArtist"
        )
        let fixture = await makeCoordinator(
            mappings: ["OldArtist": "NewArtist"],
            storedTracks: [track]
        )
        let cacheTargets = ["OldArtist", "OriginalArtist", "NewArtist"]
        for artist in cacheTargets {
            await seedCacheIdentity(
                artist: artist,
                album: "Album",
                cache: fixture.cache
            )
        }

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
        #expect(written.contains { $0.property == .artist && $0.value == "NewArtist" })
    }

    private func makeCoordinator(
        mappings: [String: String],
        testArtists: [String] = [],
        storedTracks: [Track] = []
    ) async -> (coordinator: UpdateCoordinator, bridge: MusicAppTestAccess, cache: MockCacheService) {
        let bridge = MusicAppTestAccess()
        let apiService = MockAPIService()
        let cache = MockCacheService()
        let trackStore = MockTrackStore(tracks: storedTracks)
        let effectDrain = makeTestEffectDrain(store: trackStore, cache: cache)
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            artistRenameMappings: mappings,
            testArtists: testArtists
        )

        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                writer: bridge,
                stores: .init(trackStore: trackStore, cache: cache),
                undoCoordinator: UndoCoordinator(
                    musicApp: bridge,
                    directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ArtistRenameTests-\(UUID().uuidString)")
                ),
                effectDrain: effectDrain
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: runtimeConfiguration
        )

        return (coordinator, bridge, cache)
    }

    private func makeEditableTrack(
        artist: String,
        originalArtist: String? = nil,
        albumArtist: String? = nil
    ) -> Track {
        Track(
            id: "T1",
            name: "Song",
            artist: artist,
            album: "Album",
            genre: "Rock",
            year: 2000,
            trackStatus: nil,
            originalArtist: originalArtist,
            albumArtist: albumArtist,
            appleScriptID: "T1"
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
