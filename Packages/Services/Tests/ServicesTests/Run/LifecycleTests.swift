import Foundation
import Services
import Testing

@Suite("RunLifecycle wire format")
struct LifecycleTests {
    @Test("state raw values are stable")
    func stateRawValuesAreStable() {
        #expect(RunLifecycleState.created.rawValue == "created")
        #expect(RunLifecycleState.queued.rawValue == "queued")
        #expect(RunLifecycleState.syncingLibrary.rawValue == "syncingLibrary")
        #expect(RunLifecycleState.analyzingDelta.rawValue == "analyzingDelta")
        #expect(RunLifecycleState.planningFixes.rawValue == "planningFixes")
        #expect(RunLifecycleState.awaitingReview.rawValue == "awaitingReview")
        #expect(RunLifecycleState.writing.rawValue == "writing")
        #expect(RunLifecycleState.verifying.rawValue == "verifying")
        #expect(RunLifecycleState.reporting.rawValue == "reporting")
        #expect(RunLifecycleState.completed.rawValue == "completed")
        #expect(RunLifecycleState.completedNoOp.rawValue == "completedNoOp")
        #expect(RunLifecycleState.blocked.rawValue == "blocked")
        #expect(RunLifecycleState.failed.rawValue == "failed")
        #expect(RunLifecycleState.cancelled.rawValue == "cancelled")
        #expect(RunLifecycleState.recoverable.rawValue == "recoverable")
        #expect(RunLifecycleState.recovering.rawValue == "recovering")
    }

    @Test("intent raw values are stable")
    func intentRawValuesAreStable() {
        #expect(RunIntent.observeLibrary.rawValue == "observeLibrary")
        #expect(RunIntent.previewFixes.rawValue == "previewFixes")
        #expect(RunIntent.writeFixes.rawValue == "writeFixes")
    }

    @Test("legacy transitions blob decodes")
    func legacyTransitionsBlobDecodes() throws {
        let legacyJSON = """
        [{"state":"created","timestamp":773996400},\
        {"state":"syncingLibrary","timestamp":773996401},\
        {"state":"completed","timestamp":773996460}]
        """

        let transitions = try JSONDecoder().decode(
            [RunLifecycleTransition].self,
            from: Data(legacyJSON.utf8)
        )

        #expect(transitions.map(\.state) == [.created, .syncingLibrary, .completed])
        #expect(transitions.first?.timestamp == Date(timeIntervalSinceReferenceDate: 773_996_400))
    }

    @Test("all cases round trip through Codable")
    func allCasesRoundTripThroughCodable() throws {
        for state in RunLifecycleState.allCases {
            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(RunLifecycleState.self, from: encoded)
            #expect(decoded == state)
        }
    }

    @Test("phase maps every canonical state")
    func mapsCanonicalPhases() {
        let phases: [(RunPhase, RunLifecycleState)] = [
            (.active(.created), .created),
            (.active(.queued), .queued),
            (.active(.syncingLibrary), .syncingLibrary),
            (.active(.analyzingDelta), .analyzingDelta),
            (.active(.planningFixes), .planningFixes),
            (.active(.awaitingReview), .awaitingReview),
            (.active(.writing), .writing),
            (.active(.verifying), .verifying),
            (.active(.reporting), .reporting),
            (.active(.recovering), .recovering),
            (.suspended(.blocked), .blocked),
            (.suspended(.recoverable), .recoverable),
            (.finished(.completed(.init()), finishedAt: Date(timeIntervalSinceReferenceDate: 1)), .completed),
            (.finished(.completedNoOp(.init()), finishedAt: Date(timeIntervalSinceReferenceDate: 1)), .completedNoOp),
            (.finished(.failed(message: "failed"), finishedAt: Date(timeIntervalSinceReferenceDate: 1)), .failed),
            (
                .finished(.cancelled(message: "cancelled"), finishedAt: Date(timeIntervalSinceReferenceDate: 1)),
                .cancelled
            ),
        ]

        #expect(phases.map(\.1.rawValue).sorted() == RunLifecycleState.allCases.map(\.rawValue).sorted())
        for (phase, state) in phases {
            #expect(phase.state == state)
        }
    }

    @Test("write run transitions from sync to writing, verifying, and reporting")
    func writeRunUsesWriteStages() {
        let snapshot = RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .writeFixes,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: nil,
                createdAt: Date(timeIntervalSinceReferenceDate: 20),
                reason: "write"
            ),
            startedAt: Date(timeIntervalSinceReferenceDate: 20),
            phase: .active(.syncingLibrary)
        )

        let writing = snapshot.beginningWriting()
        let verifying = writing.beginningVerifying()
        let reporting = verifying.beginningReporting()

        #expect(writing.state == .writing)
        #expect(verifying.state == .verifying)
        #expect(reporting.state == .reporting)
    }

    @Test("transitions encode as bare state strings and reference-date seconds")
    func transitionsEncodeAsBareStateStringsAndReferenceDateSeconds() throws {
        let transitions = [
            RunLifecycleTransition(state: .created, timestamp: Date(timeIntervalSinceReferenceDate: 773_996_400)),
            RunLifecycleTransition(state: .completedNoOp, timestamp: Date(timeIntervalSinceReferenceDate: 773_996_460)),
        ]

        // Encode-side pin: a self-consistent custom Codable would pass the
        // round-trip test above while silently changing what the store writes.
        let data = try JSONEncoder().encode(transitions)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(objects.count == 2)
        #expect(objects.first?["state"] as? String == "created")
        #expect(objects.first?["timestamp"] as? Double == 773_996_400)
        #expect(objects.last?["state"] as? String == "completedNoOp")
        #expect(objects.last?["timestamp"] as? Double == 773_996_460)
    }
}
