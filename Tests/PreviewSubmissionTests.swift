import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview submission")
@MainActor
struct PreviewSubmissionTests {
    @Test("Submission keeps configuration captured before queued work")
    func submissionKeepsConfiguration() async throws {
        let gate = SubmissionGate()
        let probe = SubmissionProbe()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in }
        )
        dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = 42
        dependencies.config.development.testArtists = ["Original Artist"]
        dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.hold()
                return SyncResult()
            },
            persistRunRecord: { _ in },
            produceFixPlan: { _, scope, configuration in
                await probe.record(scope: scope, configuration: configuration)
                return .empty
            }
        )))

        let submission = Task { try await dependencies.submitPreviewRun() }
        await gate.waitUntilHeld()
        dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = 91
        dependencies.config.development.testArtists = ["Changed Artist"]
        await gate.release()

        _ = try await submission.value
        #expect(await probe.configuration?.minConfidence == 42)
        #expect(await probe.scope?.normalizedTestArtists == ["Original Artist"])
    }
}

private actor SubmissionProbe {
    private(set) var configuration: FixPlanConfigurationSnapshot?
    private(set) var scope: ProcessingScopeSnapshot?

    func record(scope: ProcessingScopeSnapshot, configuration: FixPlanConfigurationSnapshot) {
        self.scope = scope
        self.configuration = configuration
    }
}

private actor SubmissionGate {
    private var isHeld = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        isHeld = true
        holdWaiters.forEach { $0.resume() }
        holdWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
