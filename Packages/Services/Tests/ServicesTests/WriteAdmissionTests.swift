import Foundation
import Testing
@testable import Core
@testable import Services

private actor WriteHold {
    private var isEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

// Safety: the lock guards the callback installed by the dispatched test script.
private final class CallbackHold: @unchecked Sendable {
    typealias Callback = @Sendable (Result<String, any Error>) -> Void

    private let lock = NSLock()
    private var callback: Callback?

    func store(_ callback: @escaping Callback) {
        lock.withLock { self.callback = callback }
    }

    func finish(_ result: Result<String, any Error>) {
        let callback = lock.withLock {
            defer { self.callback = nil }
            return self.callback
        }
        callback?(result)
    }
}

// Safety: all mutable state is protected by the lock.
private final class CallList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var values: [String] {
        lock.withLock { items }
    }
}

// Safety: the lock guards the one test result.
private final class ClearanceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func store(_ value: Bool) {
        lock.withLock { storedValue = value }
    }

    var value: Bool? {
        lock.withLock { storedValue }
    }
}

private func emptyWriteOutcome<Value: Sendable>() -> WriteOutcomeProjection<Value> {
    WriteOutcomeProjection(
        appliedTrackIDs: { _ in [] },
        partialTrackIDs: { _ in [] }
    )
}

@Suite("Write admission")
struct WriteAdmissionTests {
    @MainActor
    @Test("Recoverable validation failure has no write side effects")
    func recoverableValidationFailureHasNoWriteSideEffects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var recordedCounts: [Int] = []
        let calls = CallList()
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(
                fixedTier: .free,
                usageRecorder: { recordedCounts.append($0) }
            )
        )

        await #expect(throws: AdmissionWriteError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: {
                    calls.append("validate")
                    throw AdmissionWriteError.failed
                },
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in ["T1"] },
                    partialTrackIDs: { _ in ["T1"] }
                ),
                operation: {
                    calls.append("operation")
                    return MusicWriteResult.changed
                }
            )
        }

        #expect(calls.values == ["validate"])
        #expect(recordedCounts.isEmpty)
        #expect(await processor.recoveryHoldID() == nil)
    }

    @Test("Batch validation runs once before the first track")
    func batchValidationRunsOnceBeforeFirstTrack() async throws {
        let (directory, processor) = await makeProcessor(tier: .pro)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallList()

        _ = try await processor.process(
            tracks: [admissionTrack("T1")],
            validateWrite: { calls.append("validate") },
            operation: { _ in
                calls.append("operation")
                return []
            },
            progressHandler: ignoreAdmissionProgress
        )

        #expect(calls.values == ["validate", "operation"])
    }

    @Test("Write validation waits for reservation")
    func writeValidationWaitsForReservation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallList()
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(
                fixedTier: .free,
                freeTracksUsed: FeatureGate.freeTrackLimit
            )
        )

        await #expect(throws: FeatureGateError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: { calls.append("validate") },
                outcome: emptyWriteOutcome(),
                operation: { calls.append("operation") }
            )
        }

        #expect(calls.values.isEmpty)
    }

    @MainActor
    @Test("Recoverable writes record only returned applied track IDs")
    func recoverableWriteRecordsAppliedTracks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var recordedCounts: [Int] = []
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(
                fixedTier: .free,
                usageRecorder: { recordedCounts.append($0) }
            )
        )
        let result = BatchUpdateResult(
            entries: [
                admissionEntry(trackID: "T1"),
                admissionEntry(trackID: "T1"),
                admissionEntry(trackID: "T2"),
            ],
            noOpEntries: [admissionEntry(trackID: "T4")],
            failedTrackIDs: ["T3"],
            errorDescriptions: ["failed"]
        )

        _ = try await processor.performRecoverableWrite(
            trackCount: 3,
            features: WriteFeatureRequirements(mutation: nil),
            validateWrite: passWriteValidation,
            outcome: WriteOutcomeProjection(
                appliedTrackIDs: { Set($0.entries.map(\.trackID)) },
                partialTrackIDs: { _ in [] }
            ),
            operation: { result }
        )

        #expect(recordedCounts == [2])
    }

    @MainActor
    @Test("The same track is recorded again in a later write")
    func laterWriteRecordsSameTrackAgain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var recordedCounts: [Int] = []
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(
                fixedTier: .free,
                usageRecorder: { recordedCounts.append($0) }
            )
        )
        let result = BatchUpdateResult(
            entries: [admissionEntry(trackID: "T1")],
            failedTrackIDs: [],
            errorDescriptions: []
        )

        for _ in 0 ..< 2 {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { Set($0.entries.map(\.trackID)) },
                    partialTrackIDs: { _ in [] }
                ),
                operation: { result }
            )
        }

        #expect(recordedCounts == [1, 1])
    }

    @MainActor
    @Test("Failed recoverable writes do not record usage")
    func failedRecoverableWriteDoesNotRecordUsage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var recordedCounts: [Int] = []
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(
                fixedTier: .free,
                usageRecorder: { recordedCounts.append($0) }
            )
        )

        await #expect(throws: AdmissionWriteError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { Set($0.entries.map(\.trackID)) },
                    partialTrackIDs: { _ in [] }
                ),
                operation: { () async throws -> BatchUpdateResult in
                    throw AdmissionWriteError.failed
                }
            )
        }

        #expect(recordedCounts.isEmpty)
    }

    @MainActor
    @Test("Recoverable writes record explicitly projected partial outcomes")
    func recoverableWriteRecordsPartialOutcome() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var recordedCounts: [Int] = []
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(
                fixedTier: .free,
                usageRecorder: { recordedCounts.append($0) }
            )
        )
        let partialOutcome = AdmissionPartialWriteError(trackIDs: ["T1", "T2"])

        await #expect(throws: AdmissionPartialWriteError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 2,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { (_: BatchUpdateResult) in [] },
                    partialTrackIDs: { error in
                        (error as? AdmissionPartialWriteError)?.trackIDs ?? []
                    }
                ),
                operation: { () async throws -> BatchUpdateResult in
                    throw partialOutcome
                }
            )
        }

        #expect(recordedCounts == [2])
    }

    @MainActor
    @Test("Wrapped partial writes record known successes and rethrow the underlying error")
    func wrappedPartialWriteRecordsKnownSuccesses() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var recordedCounts: [Int] = []
        let processor = BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(
                fixedTier: .free,
                usageRecorder: { recordedCounts.append($0) }
            )
        )

        await #expect(throws: AdmissionWriteError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 3,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { (_: BatchUpdateResult) in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: { () async throws -> BatchUpdateResult in
                    throw PartialWriteError(
                        appliedTrackIDs: ["T1", "T2"],
                        underlyingError: AdmissionWriteError.failed
                    )
                }
            )
        }

        #expect(recordedCounts == [2])
    }

    @Test("Batch and external writes share one reservation")
    func sharesWriteReservation() async throws {
        let (directory, processor) = await makeProcessor(tier: .pro)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (batchHold, calls) = (WriteHold(), CallList())
        let batch = Task {
            try await processor.process(
                tracks: [admissionTrack("T1")],
                validateWrite: passWriteValidation,
                operation: { _ in
                    calls.append("batch")
                    await batchHold.wait()
                    return []
                },
                progressHandler: ignoreAdmissionProgress
            )
        }
        await batchHold.waitUntilEntered()

        await #expect(throws: BatchProcessorError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: emptyWriteOutcome(),
                operation: {
                    calls.append("external-during-batch")
                    return MusicWriteResult.changed
                }
            )
        }
        #expect(calls.values == ["batch"])
        await batchHold.release()
        _ = try await batch.value

        let externalHold = WriteHold()
        let external = Task {
            try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: emptyWriteOutcome(),
                operation: {
                    calls.append("external")
                    await externalHold.wait()
                    return MusicWriteResult.changed
                }
            )
        }
        await externalHold.waitUntilEntered()

        await #expect(throws: BatchProcessorError.self) {
            _ = try await processor.process(
                tracks: [admissionTrack("T2")],
                validateWrite: passWriteValidation,
                operation: { _ in
                    calls.append("batch-during-external")
                    return []
                },
                progressHandler: ignoreAdmissionProgress
            )
        }
        #expect(calls.values == ["batch", "external"])
        await externalHold.release()
        _ = try await external.value
    }

    @Test("A write past the free limit is refused at the reservation")
    func writePastFreeLimitIsRefusedAtReservation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(
                fixedTier: .free,
                freeTracksUsed: FeatureGate.freeTrackLimit
            )
        )
        let calls = CallList()

        // The gate used to live in WorkflowFilters, so this path — and the
        // restore, pending-verification, and fix-plan paths beside it — wrote
        // past the free limit without ever consulting it.
        await #expect(throws: FeatureGateError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: { calls.append("write") }
            )
        }
        #expect(calls.values.isEmpty)
    }

    @Test("A write within the free limit still reserves")
    func writeWithinFreeLimitReserves() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(fixedTier: .free, freeTracksUsed: 0)
        )
        let calls = CallList()

        _ = try await processor.performRecoverableWrite(
            trackCount: 1,
            features: WriteFeatureRequirements(mutation: nil),
            validateWrite: passWriteValidation,
            outcome: WriteOutcomeProjection(
                appliedTrackIDs: { _ in [] },
                partialTrackIDs: { _ in [] }
            ),
            operation: { calls.append("write") }
        )

        #expect(calls.values == ["write"])
    }

    @Test("Paid cleaning is refused before the write operation on Free")
    func refusesPaidCleaning() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(fixedTier: .free)
        )
        let calls = CallList()

        await #expect(throws: FeatureGateError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: .artistAlbumCleaning),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: { calls.append("write") }
            )
        }

        #expect(calls.values.isEmpty)
    }

    @Test("Week Pass admits paid cleaning exactly once")
    func admitsPaidCleaning() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: dir),
            featureGate: FeatureGate(fixedTier: .weekPass)
        )
        let calls = CallList()

        _ = try await processor.performRecoverableWrite(
            trackCount: 1,
            features: WriteFeatureRequirements(mutation: .artistAlbumCleaning),
            validateWrite: passWriteValidation,
            outcome: WriteOutcomeProjection(
                appliedTrackIDs: { _ in [] },
                partialTrackIDs: { _ in [] }
            ),
            operation: { calls.append("write") }
        )

        #expect(calls.values == ["write"])
    }

    @Test("Recovery clearance waits for the physical callback")
    func clearanceWaitsForCallback() async throws {
        let (directory, processor) = await makeProcessor(tier: .pro)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ScriptGate(limit: 2)
        let callback = CallbackHold()
        let dispatches = CallList()
        let outcome = try await captureUnknownOutcome(
            processor: processor,
            gate: gate,
            callback: callback,
            dispatches: dispatches
        )
        let recoveryID = try #require(await processor.recoveryHoldID())
        let completion = try #require(outcome.completion)
        let clearanceResults = await runClearanceRace(
            processor: processor,
            recoveryID: recoveryID,
            completion: completion,
            callback: callback,
            dispatches: dispatches
        )
        #expect(clearanceResults.count(where: { $0 }) == 1)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: {
                    throw AppleScriptOutcomeError(scriptName: "update_property", duration: .seconds(3))
                }
            )
        }
        let newRecoveryID = try #require(await processor.recoveryHoldID())
        #expect(newRecoveryID != recoveryID)
        try await processor.clearRecovery(batchID: newRecoveryID)

        let secondCall = ScriptCall(
            name: "update_property",
            intent: .mutation,
            deadline: ContinuousClock().now.advanced(by: .seconds(1)),
            timeout: .seconds(1)
        )
        _ = try await processor.performRecoverableWrite(
            trackCount: 1,
            features: WriteFeatureRequirements(mutation: nil),
            validateWrite: passWriteValidation,
            outcome: WriteOutcomeProjection(
                appliedTrackIDs: { _ in [] },
                partialTrackIDs: { _ in [] }
            ),
            operation: {
                try await ScriptDispatch.run(secondCall, limiter: nil, gate: gate) { finish in
                    dispatches.append("second")
                    finish(.success("done"))
                }
            }
        )
        #expect(dispatches.values == ["first", "second"])
    }

    @Test("Wrapped checkpoint outcome keeps physical completion")
    func wrappedOutcomeWaits() async throws {
        let (directory, processor) = await makeProcessor(tier: .pro)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = AppleScriptBridge(installer: ScriptInstaller(
            scriptsDirectory: directory,
            bundleScriptsDirectory: nil
        ))
        let input = writeInput()
        let itemID = try #require(input.workItems.first?.id)
        let request = RunRequest.manualWrite(input: input)
        let initial = RunLifecycleSnapshot(
            request: request,
            scope: input.scope,
            startedAt: Date(timeIntervalSince1970: 100),
            phase: .active(.writing)
        )
        let durable = try initial.applying(.beforeAttempt([itemID]))
        let checkpoint = WorkCheckpoint.afterAttempt([itemID])
        let failure = try CheckpointStoreFailure(
            checkpoint: checkpoint,
            candidate: durable.applying(checkpoint),
            durableSnapshot: durable,
            isWriteAdjacent: true,
            reason: "checkpoint store unavailable"
        )
        let completion = ScriptCompletion()

        do {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: {
                    try await bridge.applySingleUpdate(
                        musicUpdate(databaseID: testDatabaseID("101"), property: .genre, value: "Metal"),
                        onAttempt: { throw WorkCheckpointError.store(failure) },
                        execute: {
                            throw AppleScriptOutcomeError(
                                scriptName: "update_property",
                                duration: .seconds(3),
                                completion: completion
                            )
                        }
                    )
                }
            )
            Issue.record("Expected the checkpoint store failure")
        } catch {
            #expect(error is WorkCheckpointError)
        }

        let recoveryID = try #require(await processor.recoveryHoldID())
        let clearance = Task {
            try await processor.clearRecovery(batchID: recoveryID)
        }
        await waitForClearance(completion)
        #expect(completion.hasWaiters)
        completion.finish()
        try await clearance.value
    }

    private func makeProcessor(tier: Tier) async -> (directory: URL, processor: BatchProcessor) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BP-\(UUID().uuidString)")
        let processor = await BatchProcessor(
            checkpointManager: CheckpointManager(directory: directory),
            featureGate: FeatureGate(fixedTier: tier)
        )
        return (directory, processor)
    }

    private func captureUnknownOutcome(
        processor: BatchProcessor,
        gate: ScriptGate,
        callback: CallbackHold,
        dispatches: CallList
    ) async throws -> AppleScriptOutcomeError {
        do {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: {
                    // Built inside the write so the 20 ms budget measures the
                    // dispatch this test is about. Reserving a write crosses to
                    // the MainActor for the paid gate, and an absolute deadline
                    // captured before that hop times the reservation instead.
                    let firstCall = ScriptCall(
                        name: "update_property",
                        intent: .mutation,
                        deadline: ContinuousClock().now.advanced(by: .milliseconds(20)),
                        timeout: .milliseconds(20)
                    )
                    return try await ScriptDispatch.run(firstCall, limiter: nil, gate: gate) { finish in
                        dispatches.append("first")
                        callback.store(finish)
                    }
                }
            )
        } catch let error as AppleScriptOutcomeError {
            return error
        }
        Issue.record("Expected the first mutation outcome to remain unknown")
        throw AdmissionWriteError.failed
    }

    private func runClearanceRace(
        processor: BatchProcessor,
        recoveryID: UUID,
        completion: ScriptCompletion,
        callback: CallbackHold,
        dispatches: CallList
    ) async -> [Bool] {
        let firstClearance = Task {
            do {
                try await processor.clearRecovery(batchID: recoveryID)
                return true
            } catch {
                return false
            }
        }

        await waitForClearance(completion)
        #expect(completion.hasWaiters)
        let secondResult = ClearanceProbe()
        let secondClearance = Task {
            let didClear: Bool
            do {
                try await processor.clearRecovery(batchID: recoveryID)
                didClear = true
            } catch {
                didClear = false
            }
            secondResult.store(didClear)
            return didClear
        }

        await waitForResult(secondResult)
        #expect(secondResult.value == false)
        await #expect(throws: BatchProcessorError.self) {
            _ = try await processor.performRecoverableWrite(
                trackCount: 1,
                features: WriteFeatureRequirements(mutation: nil),
                validateWrite: passWriteValidation,
                outcome: WriteOutcomeProjection(
                    appliedTrackIDs: { _ in [] },
                    partialTrackIDs: { _ in [] }
                ),
                operation: {
                    dispatches.append("early-second")
                    return MusicWriteResult.changed
                }
            )
        }
        #expect(dispatches.values == ["first"])

        callback.finish(.success("done"))
        return await [firstClearance.value, secondClearance.value]
    }

    private func waitForClearance(_ completion: ScriptCompletion) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while !completion.hasWaiters, ContinuousClock().now < deadline {
            await Task.yield()
        }
    }

    private func waitForResult(_ result: ClearanceProbe) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while result.value == nil, ContinuousClock().now < deadline {
            await Task.yield()
        }
    }
}

private func admissionTrack(_ id: String) -> Track {
    Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
}

private func admissionEntry(trackID: String) -> ChangeLogEntry {
    ChangeLogEntry(changeType: .genreUpdate, trackID: trackID, artist: "Artist")
}

private enum AdmissionWriteError: Error {
    case failed
}

private struct AdmissionPartialWriteError: Error {
    let trackIDs: Set<String>
}

private func ignoreAdmissionProgress(_: ProgressUpdate) {
    // Admission tests assert write ownership, not progress reporting.
}
