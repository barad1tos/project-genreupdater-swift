import Core
import Foundation
import Testing
@testable import Services

@Suite("RunOrchestrator")
struct RunOrchestratorTests {
    @Test("manual observation captures immutable test artist scope")
    func manualObservationCapturesScope() async {
        let clock = ClockProbe()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            now: { clock.now() }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [" Aphex Twin ", "aphex twin"],
            knownTrackCount: 75
        ))

        #expect(result.lifecycle.state == .completedNoOp)
        #expect(result.lifecycle.scope.source == .testArtists)
        #expect(result.lifecycle.scope.normalizedTestArtists == ["Aphex Twin"])
        #expect(result.lifecycle.scope.knownTrackCount == 75)
    }

    @Test("manual observation returns completed when sync detects any delta")
    func manualObservationReturnsCompletedForDelta() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                SyncResult(newTracks: [
                    Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
                ])
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: 35224
        ))

        #expect(result.lifecycle.state == .completed)
        #expect(result.lifecycle.syncResult?.changeCount == 1)
    }

    @Test("manual observation stores failed lifecycle")
    func manualObservationStoresFailure() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                throw ProbeError(message: "Music.app unavailable")
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let result = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))

        #expect(result.lifecycle.state == .failed)
        #expect(result.lifecycle.failureMessage == "Music.app unavailable")
    }

    @Test("manual observation rejects a second active run")
    func manualObservationRejectsSecondActiveRun() async {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                return SyncResult()
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let first = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()

        let second = await orchestrator.submit(.manualObservation(
            requestedTestArtists: [],
            knownTrackCount: nil
        ))
        await gate.release()
        _ = await first.value

        guard case .alreadyRunning = second else {
            Issue.record("Expected alreadyRunning, got \(second)")
            return
        }
    }

    @Test("cancelling the submitter does not fail the active run")
    func cancellingSubmitterDoesNotFailActiveRun() async {
        let gate = SyncGate()
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: {
                await gate.waitUntilReleased()
                try Task.checkCancellation()
                return SyncResult()
            },
            now: { Date(timeIntervalSince1970: 100) }
        ))

        let submitter = Task {
            await orchestrator.submit(.manualObservation(
                requestedTestArtists: [],
                knownTrackCount: nil
            ))
        }
        await gate.waitUntilEntered()
        submitter.cancel()
        await gate.release()

        let result = await submitter.value
        #expect(result.lifecycle.state == .completedNoOp)
        #expect(await orchestrator.currentLifecycle()?.state == .completedNoOp)
    }

    @Test("lifecycle updates unregister subscriber after cancellation")
    func lifecycleUpdatesUnregisterSubscriberAfterCancellation() async {
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            now: { Date(timeIntervalSince1970: 100) }
        ))
        let stream = await orchestrator.lifecycleUpdates()
        let observer = Task {
            for await _ in stream {}
        }

        await waitForSubscriptionCount(orchestrator, expected: 1)
        observer.cancel()
        _ = await observer.result
        await waitForSubscriptionCount(orchestrator, expected: 0)
    }

    @Test("lifecycle replacement preserves omitted payload fields")
    func lifecycleReplacementPreservesOmittedPayloadFields() {
        let syncResult = SyncResult(newTracks: [
            Track(id: "NEW", name: "Track", artist: "Artist", album: "Album")
        ])
        let finishedAt = Date(timeIntervalSince1970: 200)
        let original = RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .observeLibrary,
            state: .completed,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: 75,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "manualCheck"
            ),
            syncResult: syncResult,
            failureMessage: "Existing failure",
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: finishedAt
        )

        let replaced = original.replacing(state: .failed)

        #expect(replaced.syncResult == syncResult)
        #expect(replaced.failureMessage == "Existing failure")
        #expect(replaced.finishedAt == finishedAt)
    }
}

private func waitForSubscriptionCount(
    _ orchestrator: RunOrchestrator,
    expected: Int
) async {
    for _ in 0 ..< 20 {
        if await orchestrator.lifecycleSubscriptionCountForTesting() == expected {
            return
        }
        await Task.yield()
    }

    Issue.record("Expected \(expected) lifecycle subscriptions")
}

private final class ClockProbe: @unchecked Sendable {
    private var timestamp: TimeInterval = 100

    func now() -> Date {
        defer { timestamp += 1 }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private actor SyncGate {
    private var hasEntered = false
    private var isReleased = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if hasEntered { return }

        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilReleased() async {
        hasEntered = true
        resumeEnteredContinuations()

        if isReleased { return }

        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }

    private func resumeEnteredContinuations() {
        for continuation in enteredContinuations {
            continuation.resume()
        }
        enteredContinuations = []
    }
}

private struct ProbeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
