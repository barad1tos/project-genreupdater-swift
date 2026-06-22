import Core
import Testing
@testable import Genre_Updater

@Suite("Workflow album identity")
@MainActor
struct WorkflowAlbumIdentityTests {
    @Test("groups collaboration tracks by album artist")
    func groupsCollaborationTracksByAlbumArtist() throws {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)
        let group = try #require(groups[AlbumIdentity.key(for: tracks[0])])

        #expect(groups.count == 1)
        #expect(Set(group.map(\.id)) == ["one", "two"])
    }

    @Test("groups collaboration tracks by primary artist when album artist is missing")
    func groupsCollaborationTracksByPrimaryArtistWhenAlbumArtistIsMissing() throws {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)
        let group = try #require(groups[AlbumIdentity.key(for: tracks[0])])

        #expect(groups.count == 1)
        #expect(Set(group.map(\.id)) == ["one", "two"])
    }

    @Test("keeps different album artists separate")
    func keepsDifferentAlbumArtistsSeparate() {
        let tracks = [
            Track(
                id: "one",
                name: "Shared Song",
                artist: "Guest Artist",
                album: "Shared Album",
                albumArtist: "First Artist"
            ),
            Track(
                id: "two",
                name: "Other Song",
                artist: "Guest Artist",
                album: "Shared Album",
                albumArtist: "Second Artist"
            ),
        ]

        let groups = WorkflowViewModel.groupTracksByAlbum(tracks)

        #expect(groups.count == 2)
        #expect(groups[AlbumIdentity.key(for: tracks[0])]?.map(\.id) == ["one"])
        #expect(groups[AlbumIdentity.key(for: tracks[1])]?.map(\.id) == ["two"])
    }

    @Test("matches pending entries with album identity")
    func matchesPendingEntriesWithAlbumIdentity() {
        let tracks = [
            Track(
                id: "one",
                name: "Get Lucky",
                artist: "Daft Punk feat. Pharrell Williams",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
            Track(
                id: "two",
                name: "Instant Crush",
                artist: "Daft Punk feat. Julian Casablancas",
                album: "Random Access Memories",
                albumArtist: "Daft Punk"
            ),
        ]
        let entries = [
            PendingAlbumEntry(
                id: "daft-punk-random-access-memories",
                artist: "Daft Punk",
                album: "Random Access Memories",
                reason: "no_year_found"
            ),
        ]

        let matchingTracks = WorkflowViewModel.tracksMatchingPendingEntries(tracks, entries: entries)

        #expect(Set(matchingTracks.map(\.id)) == ["one", "two"])
    }
}
