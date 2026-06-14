import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("Change preview grouping")
struct ChangePreviewGroupingTests {
    @Test("groups by typed artist and album key")
    func groupsByTypedArtistAndAlbumKey() {
        let changes = [
            makeProposedChange(trackID: "1", artist: "Alpha — First", album: "Live"),
            makeProposedChange(trackID: "2", artist: "Alpha", album: "First — Live"),
        ]

        let groups = ChangePreviewGrouping.groups(from: changes)

        #expect(groups.count == 2)
        #expect(Set(groups.map(\.key)) == [
            ChangePreviewGroupKey(artist: "Alpha — First", album: "Live"),
            ChangePreviewGroupKey(artist: "Alpha", album: "First — Live"),
        ])
    }

    private func makeProposedChange(
        trackID: String,
        artist: String,
        album: String
    ) -> ProposedChange {
        ProposedChange(
            track: Track(id: trackID, name: "Track \(trackID)", artist: artist, album: album),
            changeType: .genreUpdate,
            oldValue: nil,
            newValue: "Rock",
            confidence: 90,
            source: "test"
        )
    }
}
