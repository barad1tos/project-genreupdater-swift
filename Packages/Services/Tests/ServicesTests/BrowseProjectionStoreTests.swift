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

        // The first replace must actually land before dedup can hold.
        #expect(first.revision != .initial)
        #expect(second.revision == first.revision)
    }

    @Test("a content change advances the revision past the builder's initial")
    func revisionAdvancesOnChange() async {
        let store = ProjectionStore()

        let first = await store.replaceBrowseProjection(projection(artistID: "first"))
        let second = await store.replaceBrowseProjection(projection(artistID: "second"))

        // BrowseCommandTarget.projectionRevision is the staleness token:
        // a frozen revision would silently defeat stale-command checks.
        #expect(second.revision != first.revision)
        #expect(second.revision != .initial)
    }

    @Test("browse generations are independent of the chrome slot")
    func crossSlotGenerationIndependence() async {
        let store = ProjectionStore()
        _ = await store.nextChromeInputGeneration()
        _ = await store.nextChromeInputGeneration()

        let browseGeneration = await store.nextBrowseInputGeneration()
        let stored = await store.replaceBrowseProjection(
            projection(artistID: "landed"),
            inputGeneration: browseGeneration
        )

        #expect(browseGeneration == 1)
        #expect(stored.artists.first?.id == "landed")
    }

    @Test("a nil-generation replace still lands after a tagged one")
    func nilGenerationAfterTagged() async {
        let store = ProjectionStore()
        let generation = await store.nextBrowseInputGeneration()
        _ = await store.replaceBrowseProjection(
            projection(artistID: "tagged"),
            inputGeneration: generation
        )

        let stored = await store.replaceBrowseProjection(projection(artistID: "untagged"))

        #expect(stored.artists.first?.id == "untagged")
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
