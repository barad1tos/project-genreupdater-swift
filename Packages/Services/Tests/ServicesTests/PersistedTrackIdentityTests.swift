import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("PersistedTrack — identity metadata")
struct PersistedTrackIdentityTests {
    @Test("Round-trips MusicKit primary ID and AppleScript mutation ID")
    func roundTripsPrimaryAndMutationIDs() {
        let persisted = PersistedTrack(
            trackID: "MK-TRACK-1",
            appleScriptID: "AS-TRACK-1",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets",
            genre: "Metal",
            releaseYear: 1986
        )
        let restored = persisted.toTrack()

        #expect(persisted.trackID == "MK-TRACK-1")
        #expect(persisted.appleScriptID == "AS-TRACK-1")
        #expect(restored.id == "MK-TRACK-1")
        #expect(restored.appleScriptID == "AS-TRACK-1")
    }

    @Test("Update preserves processing state and refreshes AppleScript ID")
    func updateRefreshesAppleScriptID() {
        let persisted = PersistedTrack(
            trackID: "MK-TRACK-1",
            appleScriptID: "AS-OLD",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        )
        persisted.genreUpdated = true

        persisted.update(from: Track(
            id: "MK-TRACK-1",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets",
            appleScriptID: "AS-NEW"
        ))

        #expect(persisted.trackID == "MK-TRACK-1")
        #expect(persisted.appleScriptID == "AS-NEW")
        #expect(persisted.genreUpdated)
    }

    @Test("Update preserves AppleScript ID when refreshed from MusicKit-only rows")
    func updatePreservesAppleScriptIDWhenMusicKitRowHasNoMutationID() {
        let persisted = PersistedTrack(
            trackID: "MK-TRACK-1",
            appleScriptID: "AS-OLD",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets"
        )

        persisted.update(from: Track(
            id: "MK-TRACK-1",
            name: "Battery",
            artist: "Metallica",
            album: "Master of Puppets",
            appleScriptID: nil
        ))

        #expect(persisted.appleScriptID == "AS-OLD")
    }
}
