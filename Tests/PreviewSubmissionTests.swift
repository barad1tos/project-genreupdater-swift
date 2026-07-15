import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview submission")
@MainActor
struct PreviewSubmissionTests {
    @Test("Submission captures configuration before its first suspension")
    func submissionKeepsConfiguration() async throws {
        let gate = SubmissionGate()
        let probe = SubmissionProbe()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in }
        )
        dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = 42
        dependencies.config.cleaning.genreMappings = ["Electronic": "Electronica"]
        dependencies.config.development.testArtists = ["Original Artist"]
        dependencies.installTrackCountSource {
            await gate.hold()
            return 1
        }
        dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            synchronizePreview: { scope, configuration in
                await probe.recordSync(scope: scope, configuration: configuration)
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
        dependencies.config.cleaning.genreMappings = ["Electronic": "IDM"]
        dependencies.config.development.testArtists = ["Changed Artist"]
        await gate.release()

        _ = try await submission.value
        #expect(await probe.configuration?.minConfidence == 42)
        #expect(await probe.configuration?.appConfiguration.cleaning.genreMappings["Electronic"] == "Electronica")
        #expect(await probe.scope?.normalizedTestArtists == ["Original Artist"])
        #expect(await probe.syncConfiguration?.minConfidence == 42)
        #expect(await probe.syncConfiguration?.appConfiguration.cleaning.genreMappings["Electronic"] == "Electronica")
        #expect(await probe.syncScope?.normalizedTestArtists == ["Original Artist"])
    }
}

private actor SubmissionProbe {
    private(set) var configuration: FixPlanConfig?
    private(set) var scope: ProcessingScopeSnapshot?
    private(set) var syncConfiguration: FixPlanConfig?
    private(set) var syncScope: ProcessingScopeSnapshot?

    func record(scope: ProcessingScopeSnapshot, configuration: FixPlanConfig) {
        self.scope = scope
        self.configuration = configuration
    }

    func recordSync(scope: ProcessingScopeSnapshot, configuration: FixPlanConfig) {
        syncScope = scope
        syncConfiguration = configuration
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
