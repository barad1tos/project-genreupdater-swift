import Core
import Foundation
import Testing
@testable import Services

@Suite("Run work items")
struct WorkItemTests {
    @Test("Progress remains separate from explicit outcomes")
    func separatesProgressFromOutcomes() throws {
        let outcomes: [WorkOutcome] = [
            .noFixNeeded,
            .fixProposed,
            .written,
            .needsReview,
            .skipped,
            .failed,
            .deferred,
            .dismissed
        ]
        let states: [WorkState] = [
            .prepared,
            .attempting,
            .attempted,
            .outcome(.written)
        ]

        #expect(WorkOutcome.allCases.map(\.rawValue) == [
            "noFixNeeded",
            "fixProposed",
            "written",
            "needsReview",
            "skipped",
            "failed",
            "deferred",
            "dismissed"
        ])
        #expect(try JSONDecoder().decode([WorkOutcome].self, from: JSONEncoder().encode(outcomes)) == outcomes)
        #expect(try JSONDecoder().decode([WorkState].self, from: JSONEncoder().encode(states)) == states)
    }

    @Test("Album work preserves canonical album identity")
    func capturesAlbumWork() {
        let id = UUID()
        let identity = AlbumIdentity(artist: "Artist", album: "Album")

        let work = RunWorkItem(
            id: id,
            target: .album(identity),
            change: WorkChange(
                changeType: .yearUpdate,
                oldValue: nil,
                newValue: "2024",
                confidence: 87,
                source: "MusicBrainz"
            )
        )

        #expect(work.id == id)
        #expect(work.target == .album(identity))
        #expect(work.change.changeType == .yearUpdate)
        #expect(work.change.oldValue == nil)
        #expect(work.change.newValue == "2024")
        #expect(work.change.confidence == 87)
        #expect(work.change.source == "MusicBrainz")
        #expect(work.state == .prepared)
        #expect(work.detail == nil)
    }

    @Test("Track work captures the immutable fix plan item")
    func capturesTrackWork() {
        let item = FixPlanItem(
            id: UUID(),
            identity: FixPlanItemIdentity(
                readID: "music-kit-1",
                appleScriptID: "persistent-1",
                artist: "Artist",
                album: "Album",
                trackName: "Track"
            ),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 92,
            source: "MusicBrainz"
        )

        let work = RunWorkItem(item: item)

        #expect(work.id == item.id)
        #expect(work.target == .track(item.identity))
        #expect(work.change.changeType == item.changeType)
        #expect(work.change.oldValue == item.oldValue)
        #expect(work.change.newValue == item.newValue)
        #expect(work.change.confidence == item.confidence)
        #expect(work.change.source == item.source)
        #expect(work.state == .prepared)
        #expect(work.detail == nil)
    }
}
