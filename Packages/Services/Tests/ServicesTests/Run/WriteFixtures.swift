import Core
import Foundation
@testable import Services

actor WriteProbe {
    private(set) var calls: [FixPlanWriteInput] = []
    private let result: BatchUpdateResult
    private var continuations: [(Int, CheckedContinuation<Void, Never>)] = []

    init(result: BatchUpdateResult) {
        self.result = result
    }

    func apply(input: FixPlanWriteInput) throws -> BatchUpdateResult {
        calls.append(input)
        resumeContinuations()
        return result
    }

    func waitUntilCallCount(_ target: Int) async {
        if calls.count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append((target, continuation))
        }
    }

    private func resumeContinuations() {
        var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in continuations {
            if calls.count >= target {
                continuation.resume()
            } else {
                waiting.append((target, continuation))
            }
        }
        continuations = waiting
    }
}

actor WriteRecordProbe {
    private(set) var records: [RunRecord] = []

    func append(_ record: RunRecord) throws {
        records.append(record)
    }
}

actor TerminalRecordProbe {
    private(set) var records: [RunRecord] = []
    private var callCount = 0

    func append(_ record: RunRecord) throws {
        callCount += 1
        guard callCount != 2 else { throw RecordWriteError() }
        records.append(record)
    }
}

actor WriteSyncProbe {
    private(set) var callCount = 0

    func run() -> SyncResult {
        callCount += 1
        return SyncResult()
    }
}

actor WriteSyncGate {
    private var count = 0
    private var isReleased = false
    private var countContinuations: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    var callCount: Int {
        count
    }

    func sync() async -> SyncResult {
        count += 1
        resumeCountContinuations()
        if count == 1 {
            await waitUntilReleased()
        }
        return SyncResult()
    }

    func waitUntilCount(_ target: Int) async {
        if count >= target {
            return
        }
        await withCheckedContinuation { continuation in
            countContinuations.append((target, continuation))
        }
    }

    func release() {
        isReleased = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations = []
    }

    private func waitUntilReleased() async {
        if isReleased {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    private func resumeCountContinuations() {
        var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in countContinuations {
            if count >= target {
                continuation.resume()
            } else {
                waiting.append((target, continuation))
            }
        }
        countContinuations = waiting
    }
}

actor RecoveryWriteProbe {
    private(set) var calls: [FixPlanWriteInput] = []
    private var callContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func apply(input: FixPlanWriteInput) async throws -> BatchUpdateResult {
        calls.append(input)
        callContinuations.forEach { $0.resume() }
        callContinuations = []
        guard calls.count == 1 else {
            return BatchUpdateResult(entries: [writeEntry()], failedTrackIDs: [], errorDescriptions: [])
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
    }

    func waitUntilCalled() async {
        if !calls.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            callContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

struct RecordWriteError: Error {}

func writeTarget() -> FixPlanWriteTarget {
    FixPlanWriteTarget(
        planID: FixPlanID(),
        planRevision: .initial,
        decisionRevision: .initial
    )
}

func writeInput(
    target: FixPlanWriteTarget = writeTarget(),
    artists: [String] = [],
    knownTrackCount: Int? = nil
) -> FixPlanWriteInput {
    let capturedAt = Date(timeIntervalSince1970: 90)
    return FixPlanWriteInput(
        target: target,
        scope: .capture(
            requestedTestArtists: artists,
            knownTrackCount: knownTrackCount,
            createdAt: capturedAt,
            reason: "write-test"
        )
    )
}

func writeEntry() -> ChangeLogEntry {
    var entry = ChangeLogEntry(
        changeType: .genreUpdate,
        trackID: "track-1",
        artist: "Björk",
        trackName: "Jóga",
        albumName: "Homogenic"
    )
    entry.oldGenre = "Alternative"
    entry.newGenre = "Art Pop"
    return entry
}

func recoveryRecord(state: RunLifecycleState = .recoverable) -> RunRecord {
    let startedAt = Date(timeIntervalSince1970: 50)
    return RunRecord(
        runID: RunID(),
        requestID: RunRequestID(),
        trigger: .recovery,
        intent: .writeFixes,
        scope: writeInput().scope,
        writeTarget: writeTarget(),
        recoveryID: UUID(),
        transitions: [
            RunLifecycleTransition(state: .created, timestamp: startedAt),
            RunLifecycleTransition(state: .writing, timestamp: startedAt),
            RunLifecycleTransition(state: state, timestamp: startedAt),
        ],
        syncSummary: nil,
        writeSummary: nil,
        failureMessage: "Music.app verification required",
        startedAt: startedAt,
        finishedAt: nil
    )
}
