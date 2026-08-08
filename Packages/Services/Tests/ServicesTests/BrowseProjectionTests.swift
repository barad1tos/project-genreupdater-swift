import Foundation
import Testing
@testable import Services

@Suite("Browse projection type")
struct BrowseProjectionTests {
    @Test("a preview request carries its browse target")
    func previewRequestCarriesTarget() {
        let target = BrowseCommandTarget(
            albumID: "album-key",
            projectionRevision: .initial,
            scopeSnapshotID: UUID()
        )
        let command = UserIntentCommand.requestAlbumPreview(target: target)

        #expect(command.kind == .requestAlbumPreview)
        #expect(command.browseTarget == target)
        #expect(command.fixPlanTarget == nil)
    }

    @Test("the empty sentinel carries no library truth")
    func emptySentinel() {
        let empty = BrowseProjection.empty()

        #expect(empty.revision == .initial)
        #expect(empty.artists.isEmpty)
        #expect(empty.scope == nil)
        #expect(empty.physicalTrackCount == nil)
        #expect(empty.readSource == nil)
        #expect(empty.operationalIssues.isEmpty)
    }

    @Test("withRevision changes only the revision")
    func revisionNeutralContent() {
        let projection = BrowseProjection.empty()
        let advanced = projection.withRevision(ProjectionRevision.initial.advanced())

        #expect(advanced.revision != projection.revision)
        #expect(advanced.withRevision(projection.revision) == projection)
    }

    @Test("artist counts aggregate album counts")
    func artistCountsAggregate() {
        let artist = BrowseArtistNode(
            id: "artist",
            name: "Artist",
            albums: [
                BrowseAlbumNode(
                    id: "a1",
                    title: "One",
                    artistName: "Artist",
                    genre: "Rock",
                    year: 2001,
                    counts: BrowseNodeCounts(total: 10, inScope: 10, writable: 8),
                    action: ChromeCommandDescriptor(
                        id: "browse-preview-a1",
                        title: "Preview changes",
                        isEnabled: true,
                        commandKind: .requestAlbumPreview
                    )
                ),
                BrowseAlbumNode(
                    id: "a2",
                    title: "Two",
                    artistName: "Artist",
                    genre: nil,
                    year: nil,
                    counts: BrowseNodeCounts(total: 5, inScope: 0, writable: 0),
                    action: ChromeCommandDescriptor(
                        id: "browse-preview-a2",
                        title: "Preview changes",
                        isEnabled: false,
                        disabledReason: "Outside the current Test Artists scope.",
                        commandKind: .requestAlbumPreview
                    )
                ),
            ]
        )

        #expect(artist.counts == BrowseNodeCounts(total: 15, inScope: 10, writable: 8))
    }
}
