import Core
import Services
import Testing

@Suite("Track ID merge")
struct TrackIDMergeTests {
    @Test("refresh clears a stale mapping for a refreshed track")
    func clearsStaleMapping() async {
        let mapper = TrackIDMapper()
        let musicKitTrack = track(id: "MK-1", name: "Old Name")

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [track(id: "AS-OLD", name: "Old Name")]
        )
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [track(id: "AS-OTHER", name: "Other Name")],
            mergeExisting: true
        )

        #expect(await mapper.appleScriptID(forMusicKitID: "MK-1") == nil)
        #expect(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack) == nil)
    }

    @Test("refresh replaces a stale mapping with a fresh match")
    func replacesStaleMapping() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = track(id: "MK-1", name: "Track")

        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [track(id: "AS-OLD", name: "Track", genre: "Rock")]
        )
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [track(id: "AS-NEW", name: "Track", genre: "Electronic")],
            mergeExisting: true
        )

        let enrichedTrack = try #require(await mapper.trackWithAppleScriptMetadata(for: musicKitTrack))
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-1") == "AS-NEW")
        #expect(enrichedTrack.id == "MK-1")
        #expect(enrichedTrack.appleScriptID == "AS-NEW")
        #expect(enrichedTrack.genre == "Electronic")
    }

    private func track(id: String, name: String, genre: String? = nil) -> Track {
        Track(id: id, name: name, artist: "Artist", album: "Album", genre: genre)
    }
}
