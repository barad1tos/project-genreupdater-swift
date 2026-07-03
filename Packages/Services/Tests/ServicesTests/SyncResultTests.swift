import Testing
@testable import Core
@testable import Services

@Suite("SyncResult — hasChanges computed property")
struct SyncResultTests {
    @Test("hasChanges is false for empty result")
    func emptyResult() {
        let result = SyncResult()
        #expect(result.hasChanges == false)
    }

    @Test("hasChanges is true when newTracks is non-empty")
    func hasNewTracks() {
        let track = Track(id: "1", name: "Song", artist: "A", album: "B")
        let result = SyncResult(newTracks: [track])
        #expect(result.hasChanges == true)
    }

    @Test("hasChanges is true when removedTrackIDs is non-empty")
    func hasRemovedTracks() {
        let result = SyncResult(removedTrackIDs: ["1"])
        #expect(result.hasChanges == true)
    }

    @Test("hasChanges is true when modifiedTracks is non-empty")
    func hasModifiedTracks() {
        let track = Track(id: "1", name: "Song", artist: "A", album: "B")
        let result = SyncResult(modifiedTracks: [track])
        #expect(result.hasChanges == true)
    }

    @Test("hasChanges is true when refreshedTracks is non-empty")
    func hasRefreshedTracks() {
        let track = Track(id: "1", name: "Song", artist: "A", album: "B")
        let result = SyncResult(refreshedTracks: [track])
        #expect(result.hasChanges == true)
    }

    @Test("changeCount totals all sync buckets")
    func changeCountTotalsAllSyncBuckets() {
        let firstTrack = Track(id: "1", name: "Song 1", artist: "A", album: "B")
        let secondTrack = Track(id: "2", name: "Song 2", artist: "A", album: "B")
        let result = SyncResult(
            newTracks: [firstTrack],
            modifiedTracks: [secondTrack],
            identityChangedTracks: [firstTrack],
            refreshedTracks: [secondTrack],
            removedTrackIDs: ["old-1", "old-2"]
        )

        #expect(result.changeCount == 6)
        #expect(result.hasChanges == true)
    }
}
