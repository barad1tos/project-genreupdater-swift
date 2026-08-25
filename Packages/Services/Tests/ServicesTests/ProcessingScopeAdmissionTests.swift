import Core
import Foundation
import Testing
@testable import Services

/// Slice 15: an album-targeted read request admits exactly the target
/// album's tracks — including collaboration spellings via the identity
/// alias list — while the artist allow-list keeps its own veto.
@Suite("Processing track scope admission")
struct ProcessingScopeAdmissionTests {
    private let target = AlbumIdentity(artist: "Daft Punk", album: "Random Access Memories")

    @Test("a canonical member is admitted")
    func canonicalMemberAdmitted() {
        let request = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "1",
            name: "Contact",
            artist: "Daft Punk",
            album: "Random Access Memories"
        )

        #expect(request.admits(track))
    }

    @Test("a collaboration spelling is admitted through the split alias")
    func collaborationSpellingAdmitted() {
        let request = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "2",
            name: "Get Lucky",
            artist: "Daft Punk feat. Pharrell Williams",
            album: "Random Access Memories"
        )

        #expect(request.admits(track))
    }

    @Test("the same album name under a different artist is rejected")
    func differentArtistRejected() {
        let request = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "3",
            name: "Song",
            artist: "Someone Else",
            album: "Random Access Memories"
        )

        #expect(!request.admits(track))
    }

    @Test("a different album is rejected")
    func differentAlbumRejected() {
        let request = ProcessingTrackScope(albumIdentity: target)
        let track = Track(
            id: "4",
            name: "Around the World",
            artist: "Daft Punk",
            album: "Homework"
        )

        #expect(!request.admits(track))
    }

    @Test("the artist allow-list keeps its veto alongside the identity")
    func allowListVetoStands() {
        let request = ProcessingTrackScope(
            testArtists: ["Aphex Twin"],
            albumIdentity: target
        )
        let track = Track(
            id: "5",
            name: "Contact",
            artist: "Daft Punk",
            album: "Random Access Memories"
        )

        #expect(!request.admits(track))
    }

    @Test("without an identity the request is a pure allow-list")
    func nilIdentityIsPureAllowList() {
        let request = ProcessingTrackScope(testArtists: ["Daft Punk"])
        let inScope = Track(id: "6", name: "Song", artist: "Daft Punk", album: "Any")
        let outOfScope = Track(id: "7", name: "Song", artist: "Other", album: "Any")

        #expect(request.admits(inScope))
        #expect(!request.admits(outOfScope))
    }
}
