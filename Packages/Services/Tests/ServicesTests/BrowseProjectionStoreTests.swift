import Foundation
import Testing
@testable import Services

@Suite("Browse projection store slot")
struct BrowseProjectionStoreTests {
    private func projection(artistID: String) -> BrowseProjection {
        BrowseProjection(
            revision: .initial,
            artists: [BrowseArtistNode(id: artistID, name: artistID, albums: [])],
            scope: nil,
            physicalTrackCount: nil,
            readSource: nil,
            operationalIssues: []
        )
    }

    @Test("a content-identical replace keeps the revision")
    func dedupKeepsRevision() async {
        let store = ProjectionStore()

        let first = await store.replaceBrowseProjection(projection(artistID: "same"))
        let second = await store.replaceBrowseProjection(projection(artistID: "same"))

        #expect(second.revision == first.revision)
    }

    @Test("a stale input generation is dropped")
    func staleGenerationDropped() async {
        let store = ProjectionStore()
        let olderGeneration = await store.nextBrowseInputGeneration()
        let newerGeneration = await store.nextBrowseInputGeneration()

        // Newer facts land first; the older claimant must not overwrite.
        let stored = await store.replaceBrowseProjection(
            projection(artistID: "newer"),
            inputGeneration: newerGeneration
        )
        let afterStale = await store.replaceBrowseProjection(
            projection(artistID: "older"),
            inputGeneration: olderGeneration
        )

        #expect(afterStale == stored)
        #expect(await store.currentBrowse().artists.first?.id == "newer")
    }

    @Test("an existing subscriber receives the replaced projection")
    func broadcastReachesSubscriber() async {
        let store = ProjectionStore()
        let updates = await store.browseUpdates()
        var iterator = updates.makeAsyncIterator()
        // Subscribing yields the current snapshot first.
        let initial = await iterator.next()
        #expect(initial?.artists.isEmpty == true)

        _ = await store.replaceBrowseProjection(projection(artistID: "published"))

        let received = await iterator.next()
        #expect(received?.artists.first?.id == "published")
    }
}
