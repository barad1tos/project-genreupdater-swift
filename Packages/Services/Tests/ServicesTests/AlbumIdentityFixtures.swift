@testable import Core

extension AlbumIdentityFlowTests {
    func collaborationTracks() -> [Track] {
        [
            makeTrack(
                id: "ram-1",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ),
            makeTrack(
                id: "ram-2",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                year: 2013
            ),
            makeTrack(
                id: "ram-3",
                artist: "Daft Punk",
                album: "Random Access Memories",
                year: 2013
            ),
        ]
    }

    func enrichedTracks() -> (musicKit: [Track], appleScript: [Track]) {
        let musicKit = [
            makeTrack(
                id: "mk-1",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories"
            ),
            makeTrack(
                id: "mk-2",
                name: "Instant Crush",
                artist: "Julian Casablancas",
                album: "Random Access Memories",
                year: 2001
            ),
            makeTrack(
                id: "mk-3",
                name: "Fragments of Time",
                artist: "Todd Edwards",
                album: "Random Access Memories",
                year: 2001
            ),
        ]
        let appleScript = [
            makeTrack(
                id: "as-1",
                name: "Get Lucky",
                artist: "Pharrell Williams",
                album: "Random Access Memories",
                trackStatus: TrackKind.subscription.rawValue,
                metadata: .init(albumArtist: "Daft Punk")
            ),
            makeTrack(
                id: "as-2",
                name: "Instant Crush",
                artist: "Julian Casablancas",
                album: "Random Access Memories",
                year: 2001,
                trackStatus: TrackKind.subscription.rawValue,
                metadata: .init(albumArtist: "Daft Punk")
            ),
            makeTrack(
                id: "as-3",
                name: "Fragments of Time",
                artist: "Todd Edwards",
                album: "Random Access Memories",
                year: 2001,
                trackStatus: TrackKind.subscription.rawValue,
                metadata: .init(albumArtist: "Daft Punk")
            ),
        ]
        return (musicKit, appleScript)
    }
}
