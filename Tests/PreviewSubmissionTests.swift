import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview submission")
@MainActor
struct PreviewSubmissionTests {
    @Test("Manual Run submits the canonical fix-plan pipeline with captured mode")
    func manualRunSubmitsFixPlanPipeline() async throws {
        let probe = SubmissionProbe()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in }
        )
        dependencies.config.runtime.dryRun = false
        dependencies.config.runtime.automationStrategy = .hybrid
        dependencies.installTrackCountSource { 1 }
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
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

        let result = try await dependencies.submitManualRun()

        #expect(result.lifecycle?.intent == .previewFixes)
        #expect(result.lifecycle?.configuration?.mode == .autoFix)
        #expect(result.lifecycle?.configuration?.automation == .hybrid)
        #expect(await probe.configuration != nil)
        #expect(await probe.syncConfiguration != nil)
    }

    @Test("Submission captures configuration before its first suspension")
    func submissionKeepsConfiguration() async throws {
        let gate = SubmissionGate()
        let probe = SubmissionProbe()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // This test keeps configuration in memory.
            }
        )
        dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = 42
        dependencies.config.yearRetrieval.apiAuth.discogsTokenReference = "submitted-token"
        dependencies.config.cleaning.genreMappings = ["Electronic": "Electronica"]
        dependencies.config.development.testArtists = ["Original Artist"]
        dependencies.installTrackCountSource {
            await gate.hold()
            return 1
        }
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            synchronizePreview: { scope, configuration in
                await probe.recordSync(scope: scope, configuration: configuration)
                return SyncResult()
            },
            persistRunRecord: { _ in
                // Persistence is outside the submission contract under test.
            },
            produceFixPlan: { _, scope, configuration in
                await probe.record(scope: scope, configuration: configuration)
                return .empty
            }
        )))

        let tokenProbe = SubmittedTokenProbe()
        let factoryOverrides = makeFactory(tokenProbe: tokenProbe)
        let submission = Task {
            try await dependencies.submitPreviewRun(factoryOverrides: factoryOverrides)
        }
        await gate.waitUntilHeld()
        dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = 91
        dependencies.config.yearRetrieval.apiAuth.discogsTokenReference = "rotated-token"
        dependencies.config.cleaning.genreMappings = ["Electronic": "IDM"]
        dependencies.config.development.testArtists = ["Changed Artist"]
        await gate.release()

        _ = try await submission.value
        #expect(await probe.configuration?.minConfidence == 42)
        #expect(await probe.configuration?.albumTarget == nil)
        #expect(await probe.configuration?.hasDiscogsAccess == true)
        #expect(await probe.configuration?.appConfiguration.cleaning.genreMappings["Electronic"] == "Electronica")
        #expect(await probe.scope?.normalizedTestArtists == ["Original Artist"])
        #expect(await probe.syncConfiguration?.minConfidence == 42)
        #expect(await probe.syncConfiguration?.hasDiscogsAccess == true)
        #expect(await probe.syncConfiguration?.appConfiguration.cleaning.genreMappings["Electronic"] == "Electronica")
        #expect(await probe.syncScope?.normalizedTestArtists == ["Original Artist"])
        #expect(tokenProbe.token == "submitted-token")
        let submittedConfiguration = try #require(await probe.configuration)
        let submittedAccess = await dependencies.discogsAccessStore.consume(
            configurationID: submittedConfiguration.id
        )
        #expect(submittedAccess?.isEnabled == true)
    }

    @Test("Submission carries the album target into the captured configuration")
    func submissionCarriesAlbumTarget() async throws {
        let probe = SubmissionProbe()
        let dependencies = AppDependencies(
            configurationLoader: { AppConfiguration() },
            configurationSaver: { _ in
                // This test keeps configuration in memory.
            }
        )
        dependencies.installTrackCountSource { 1 }
        await dependencies.installTestOrchestrator(RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            synchronizePreview: { scope, configuration in
                await probe.recordSync(scope: scope, configuration: configuration)
                return SyncResult()
            },
            persistRunRecord: { _ in
                // Persistence is outside the submission contract under test.
            },
            produceFixPlan: { _, scope, configuration in
                await probe.record(scope: scope, configuration: configuration)
                return .empty
            }
        )))

        let target = FixPlanAlbumTarget(artist: "Clutch", album: "Blast Tyrant")
        _ = try await dependencies.submitPreviewRun(albumTarget: target)

        #expect(await probe.configuration?.albumTarget == target)
    }
}

private func makeFactory(tokenProbe: SubmittedTokenProbe) -> APIClientFactoryOverrides {
    APIClientFactoryOverrides(
        configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
            tokenProbe.record(token)
            return DiscogsClient(
                token: token,
                contactEmail: contactEmail,
                rateLimiter: rateLimiter,
                baseURL: baseURL
            )
        }
    )
}

private final class SubmittedTokenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var token: String? {
        lock.withLock { value }
    }

    func record(_ token: String) {
        lock.withLock { value = token }
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
