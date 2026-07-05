import Foundation
import Services
import Testing

@Suite("RunLifecycle wire format")
struct RunLifecycleTests {
    @Test("state raw values are stable")
    func stateRawValuesAreStable() {
        #expect(RunLifecycleState.created.rawValue == "created")
        #expect(RunLifecycleState.syncingLibrary.rawValue == "syncingLibrary")
        #expect(RunLifecycleState.reporting.rawValue == "reporting")
        #expect(RunLifecycleState.completed.rawValue == "completed")
        #expect(RunLifecycleState.completedNoOp.rawValue == "completedNoOp")
        #expect(RunLifecycleState.failed.rawValue == "failed")
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
        let states: [RunLifecycleState] = [
            .created, .syncingLibrary, .reporting, .completed, .completedNoOp, .failed,
        ]

        for state in states {
            let encoded = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(RunLifecycleState.self, from: encoded)
            #expect(decoded == state)
        }
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
