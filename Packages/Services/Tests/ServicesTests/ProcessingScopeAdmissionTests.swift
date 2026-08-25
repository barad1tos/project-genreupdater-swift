import Core
import Foundation
import Testing
@testable import Services

/// Album-targeted processing admits only the target album's tracks, including
/// collaboration spellings from the identity alias list, while the artist
/// allow-list keeps its own veto.
@Suite("Processing track scope admission")
struct ProcessingScopeAdmissionTests {
    private let target = AlbumIdentity(artist: "Daft Punk", album: "Random Access Memories")

    @Test("a canonical member is admitted")
    func canonicalMemberAdmitted() {
        let scope = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "1",
            name: "Contact",
            artist: "Daft Punk",
            album: "Random Access Memories"
        )

        #expect(scope.admits(track))
    }

    @Test("a collaboration spelling is admitted through the split alias")
    func collaborationSpellingAdmitted() {
        let scope = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "2",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories"
        )

        #expect(scope.admits(track))
    }

    @Test("the same album name under a different artist is rejected")
    func differentArtistRejected() {
        let scope = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "3",
            name: "Song",
            artist: "Someone Else",
            album: "Random Access Memories"
        )

        #expect(!scope.admits(track))
    }

    @Test("a different album is rejected")
    func differentAlbumRejected() {
        let scope = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "4",
            name: "Around the World",
            artist: "Daft Punk",
            album: "Homework"
        )

        #expect(!scope.admits(track))
    }

    @Test("the artist allow-list keeps its veto alongside the identity")
    func allowListVetoStands() {
        let scope = ProcessingTrackScope(
            testArtists: ["Aphex Twin"],
            albumIdentity: target
        )
        let track = Track(
            id: "5",
            name: "Contact",
            artist: "Daft Punk",
            album: "Random Access Memories"
        )

        #expect(!scope.admits(track))
    }

    @Test("without an identity the scope is a pure allow-list")
    func nilIdentityIsPureAllowList() {
        let scope = ProcessingTrackScope(testArtists: ["Daft Punk"])
        let inScope = Track(id: "6", name: "Song", artist: "Daft Punk", album: "Any")
        let outOfScope = Track(id: "7", name: "Song", artist: "Other", album: "Any")

        #expect(scope.admits(inScope))
        #expect(!scope.admits(outOfScope))
    }
}
