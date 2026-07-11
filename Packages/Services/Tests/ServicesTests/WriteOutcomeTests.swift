import Core
import Foundation
import Testing
@testable import Services

@Suite("Write outcome safety")
struct WriteOutcomeTests {
    @Test("Single write preserves an unknown outcome")
    func preservesUnknownOutcome() async {
        let bridge = MockAppleScriptClient()
        let outcome = AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        await bridge.setCustomWriteError(outcome)
        let cache = MockCacheService()
        let undo = UndoCoordinator(
            scriptBridge: bridge,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("WriteOutcomeTests-\(UUID().uuidString)")
        )
        let api = MockAPIService(yearResult: YearResult())
        let coordinator = UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: api,
                    discogs: api,
                    appleMusic: api
                ),
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: undo
            ),
            genreDeterminator: GenreDeterminator()
        )
        let change = ProposedChange(
            track: Track(
                id: "T1",
                name: "Track",
                artist: "Artist",
                album: "Album",
                genre: "Rock"
            ),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Pop",
            confidence: 90,
            source: "test",
            isAccepted: true
        )

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.applyChange(change, isReviewedChange: false)
        }
    }

    @Test("Undo preserves an unknown outcome")
    func preservesUnknownUndoOutcome() async {
        let bridge = MockAppleScriptClient()
        let outcome = AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
        await bridge.setCustomWriteError(outcome)
        let coordinator = UndoCoordinator(
            scriptBridge: bridge,
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("UndoOutcomeTests-\(UUID().uuidString)")
        )
        var entry = ChangeLogEntry(
            changeType: .yearUpdate,
            trackID: "T1",
            artist: "Artist",
            trackName: "Track",
            albumName: "Album"
        )
        entry.oldYear = 1984
        entry.newYear = 2000

        await #expect(throws: AppleScriptOutcomeError.self) {
            try await coordinator.revertChange(entry)
        }
    }
}
