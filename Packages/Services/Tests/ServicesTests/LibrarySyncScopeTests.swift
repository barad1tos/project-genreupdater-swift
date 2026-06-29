import Testing
@testable import Core
@testable import Services

@Suite("LibrarySyncService - configured scope")
struct LibrarySyncScopeTests {
    @Test("Scoped sync uses AppleScript when read provider is available")
    func scopedSyncUsesAppleScriptWhenReadProviderIsAvailable() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)
        let readProvider = SyncMockReadProvider()

        await readProvider.setTracks([])
        await bridge.setArtistTracks([
            Track(
                id: "AS-APHEX",
                name: "Windowlicker",
                artist: "Aphex Twin",
                album: "Windowlicker",
                appleScriptID: "AS-APHEX"
            ),
        ], for: "Aphex Twin")
        await store.setStored([
            Track(
                id: "AS-APHEX",
                name: "Windowlicker",
                artist: "Aphex Twin",
                album: "Windowlicker",
                appleScriptID: "AS-APHEX"
            ),
            Track(
                id: "MK-OUTSIDE",
                name: "Outside Scope",
                artist: "Boards of Canada",
                album: "Music Has the Right to Children",
                appleScriptID: "AS-OUTSIDE"
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: [" Aphex Twin "]),
            readProvider: readProvider
        )

        let result = try await service.detectChanges()

        #expect(result.hasChanges == false)
        #expect(await readProvider.requestCount() == 0)
        #expect(await bridge.fetchedArtists() == ["Aphex Twin"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 0)
    }

    @Test("AppleScript fallback sync uses configured test artist scope")
    func appleScriptFallbackSyncUsesConfiguredTestArtistScope() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        await bridge.setLibrary(ids: ["AS-OUTSIDE"], tracks: [
            "AS-OUTSIDE": Track(
                id: "AS-OUTSIDE",
                name: "Outside Scope",
                artist: "Boards of Canada",
                album: "Music Has the Right to Children",
                appleScriptID: "AS-OUTSIDE"
            ),
        ])
        await bridge.setArtistTracks([
            Track(
                id: "AS-APHEX",
                name: "Windowlicker",
                artist: "Aphex Twin",
                album: "Windowlicker",
                appleScriptID: "AS-APHEX"
            ),
        ], for: "Aphex Twin")
        await store.setStored([
            Track(
                id: "AS-APHEX",
                name: "Windowlicker",
                artist: "Aphex Twin",
                album: "Windowlicker",
                appleScriptID: "AS-APHEX"
            ),
            Track(
                id: "AS-OUTSIDE",
                name: "Outside Scope",
                artist: "Boards of Canada",
                album: "Music Has the Right to Children",
                appleScriptID: "AS-OUTSIDE"
            ),
        ])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: [" Aphex Twin "])
        )

        let result = try await service.detectChanges()

        #expect(result.hasChanges == false)
        #expect(await bridge.fetchedArtists() == ["Aphex Twin"])
        #expect(await bridge.fetchAllTrackIDsCallCount() == 0)
        #expect(await bridge.fetchTracksRequestCount() == 0)
    }

    @Test("AppleScript fallback reconciles artist scope through effective artist")
    func appleScriptFallbackUsesEffectiveArtistScope() async throws {
        let bridge = SyncMockScriptClient()
        let store = SyncMockTrackStore()
        let gate = await FeatureGate(fixedTier: .free)

        let includedTrack = Track(
            id: "AS-ALBUM-ARTIST",
            name: "Alberto Balsalm",
            artist: "Richard D. James",
            album: "...I Care Because You Do",
            albumArtist: "Aphex Twin",
            appleScriptID: "AS-ALBUM-ARTIST"
        )
        let excludedTrack = Track(
            id: "AS-ARTIST-ONLY",
            name: "Outside Compilation",
            artist: "Aphex Twin",
            album: "Compiler",
            albumArtist: "Various Artists",
            appleScriptID: "AS-ARTIST-ONLY"
        )

        await bridge.setArtistTracks([includedTrack, excludedTrack], for: "Aphex Twin")
        await store.setStored([includedTrack, excludedTrack])

        let service = LibrarySyncService(
            scriptBridge: bridge,
            trackStore: store,
            featureGate: gate,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Aphex Twin"])
        )

        let result = try await service.detectChanges()

        #expect(result.hasChanges == false)
        #expect(result.newTracks.isEmpty)
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await bridge.fetchedArtists() == ["Aphex Twin"])
    }
}
