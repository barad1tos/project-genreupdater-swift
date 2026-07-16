import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator preview release")
struct PreviewReleaseTests {
    @Test("active preview covers duplicate submission")
    func previewCoversDuplicate() async {
        let gate = PreviewGate()
        let releases = PreviewReleaseProbe()
        let activeConfiguration = makePreviewConfiguration()
        let duplicateConfiguration = makePreviewConfiguration()
        let orchestrator = makeOrchestrator(gate: gate, releases: releases)

        let first = Task {
            await orchestrator.submit(.manualPreview(
                configuration: activeConfiguration,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        let second = await orchestrator.submit(.manualPreview(
            configuration: duplicateConfiguration,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        #expect(await releases.configurationIDs == [duplicateConfiguration.id])
        await gate.release()
        _ = await first.value
        await releases.waitForCount(2)

        guard case let .alreadyCovered(snapshot) = second else {
            Issue.record("Expected alreadyCovered, got \(second)")
            return
        }
        #expect(snapshot.state == .planningFixes)
        #expect(await releases.configurationIDs == [duplicateConfiguration.id, activeConfiguration.id])
    }

    @Test("covered preview releases stale pending without releasing active access")
    func coveredPreviewReleasesPending() async {
        let gate = PreviewGate()
        let releases = PreviewReleaseProbe()
        let activeConfiguration = makePreviewConfiguration(minConfidence: 50)
        let pendingConfiguration = makePreviewConfiguration(minConfidence: 70)
        let orchestrator = makeOrchestrator(gate: gate, releases: releases)

        let active = Task {
            await orchestrator.submit(.manualPreview(
                configuration: activeConfiguration,
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        let queued = await orchestrator.submit(.manualPreview(
            configuration: pendingConfiguration,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        let covered = await orchestrator.submit(.manualPreview(
            configuration: activeConfiguration,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .queued = queued, case .alreadyCovered = covered else {
            Issue.record("Expected queued pending preview and covered active preview")
            return
        }
        #expect(await releases.configurationIDs == [pendingConfiguration.id])

        await gate.release()
        _ = await active.value
        await releases.waitForCount(2)
        #expect(await releases.configurationIDs == [pendingConfiguration.id, activeConfiguration.id])
    }

    @Test("superseded pending preview is released")
    func releasesSupersededPreview() async {
        let gate = PreviewGate()
        let releases = PreviewReleaseProbe()
        let firstConfiguration = makePreviewConfiguration(minConfidence: 70)
        let replacementConfiguration = makePreviewConfiguration(minConfidence: 80)
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            persistRunRecord: ignorePreviewRecord,
            produceFixPlan: { _, _, _ in .empty },
            releasePreview: { await releases.record($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let active = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        let first = await orchestrator.submit(.manualPreview(
            configuration: firstConfiguration,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        let replacement = await orchestrator.submit(.manualPreview(
            configuration: replacementConfiguration,
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        guard case .queued = first, case .queued = replacement else {
            Issue.record("Expected both preview submissions to queue")
            return
        }
        #expect(await releases.configurationIDs == [firstConfiguration.id])

        await gate.release()
        _ = await active.value
        await releases.waitForCount(2)
        #expect(await releases.configurationIDs == [firstConfiguration.id, replacementConfiguration.id])
    }

    private func makeOrchestrator(
        gate: PreviewGate,
        releases: PreviewReleaseProbe
    ) -> RunOrchestrator {
        RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: ignorePreviewRecord,
            produceFixPlan: { _, _, _ in
                await gate.waitUntilReleased()
                return .empty
            },
            releasePreview: { await releases.record($0) },
            now: { Date(timeIntervalSince1970: 100) }
        ))
    }
}

private func makePreviewConfiguration(minConfidence: Int = 50) -> FixPlanConfig {
    FixPlanConfig.capture(
        configuration: AppConfiguration(),
        options: UpdateOptions(minConfidence: minConfidence),
        capturedAt: Date(timeIntervalSince1970: 50)
    )
}

private func ignorePreviewRecord(_ record: RunRecord) async throws {
    _ = record
}

private actor PreviewReleaseProbe {
    private(set) var configurationIDs: [UUID] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ configuration: FixPlanConfig) {
        configurationIDs.append(configuration.id)
        let ready = waiters.filter { configurationIDs.count >= $0.0 }
        waiters.removeAll { configurationIDs.count >= $0.0 }
        for waiter in ready {
            waiter.1.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        guard configurationIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor PreviewGate {
    private var hasEntered = false
    private var isReleased = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitUntilReleased() async {
        hasEntered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}
