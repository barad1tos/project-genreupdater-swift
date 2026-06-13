import Testing
@testable import Core

@Suite("ProgressUpdate — Phase 2A")
struct ProgressUpdateTests {
    @Test("fractionComplete calculates correctly")
    func fractionComplete() {
        let update = ProgressUpdate(phase: .analyzing, current: 25, total: 100)
        #expect(update.fractionComplete == 0.25)
    }

    @Test("fractionComplete returns 0 when total is 0")
    func fractionCompleteZeroTotal() {
        let update = ProgressUpdate(phase: .fetching, current: 0, total: 0)
        #expect(update.fractionComplete == 0)
    }

    @Test("fractionComplete returns 1.0 when complete")
    func fractionCompleteFullProgress() {
        let update = ProgressUpdate(phase: .complete, current: 50, total: 50)
        #expect(update.fractionComplete == 1.0)
    }

    @Test("isComplete is true only for .complete phase")
    func isCompleteFlag() {
        let inProgress = ProgressUpdate(phase: .updating, current: 10, total: 20)
        #expect(!inProgress.isComplete)

        let done = ProgressUpdate(phase: .complete, current: 20, total: 20)
        #expect(done.isComplete)
    }

    @Test("message is optional and preserved")
    func optionalMessage() {
        let withMessage = ProgressUpdate(phase: .fetching, current: 1, total: 10, message: "Loading tracks")
        #expect(withMessage.message == "Loading tracks")

        let noMessage = ProgressUpdate(phase: .fetching, current: 1, total: 10)
        #expect(noMessage.message == nil)
    }

    @Test("Equatable conformance works")
    func equatable() {
        let first = ProgressUpdate(phase: .analyzing, current: 5, total: 10, message: "test")
        let second = ProgressUpdate(phase: .analyzing, current: 5, total: 10, message: "test")
        let different = ProgressUpdate(phase: .analyzing, current: 6, total: 10, message: "test")

        #expect(first == second)
        #expect(first != different)
    }

    @Test("ProcessingPhase has all expected cases")
    func phasesCoverage() {
        let allCases = ProcessingPhase.allCases
        #expect(allCases.count == 4)
        #expect(allCases.contains(.fetching))
        #expect(allCases.contains(.analyzing))
        #expect(allCases.contains(.updating))
        #expect(allCases.contains(.complete))
    }

    @Test("ProcessingPhase rawValue matches expected strings")
    func phaseRawValues() {
        #expect(ProcessingPhase.fetching.rawValue == "fetching")
        #expect(ProcessingPhase.analyzing.rawValue == "analyzing")
        #expect(ProcessingPhase.updating.rawValue == "updating")
        #expect(ProcessingPhase.complete.rawValue == "complete")
    }
}
