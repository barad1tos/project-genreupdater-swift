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

    private func track(id: String, name: String) -> Track {
        Track(id: id, name: name, artist: "Artist", album: "Album")
    }
}
