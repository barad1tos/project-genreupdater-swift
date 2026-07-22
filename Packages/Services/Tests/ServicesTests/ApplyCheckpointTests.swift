import Foundation
import Testing
@testable import Core
@testable import Services

extension ApplyAcceptedTests {
    @Test("Checkpoint store failures stop the reviewed write group")
    func stopsAfterStoreFailure() async {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        let proposals = [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library"
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz"
            ),
        ]
        let checkpoints = CheckpointProbe()
        let failure = storeFailure(for: .beforeAttempt([proposals[0].id]))

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    await checkpoints.append(checkpoint)
                    if await checkpoints.values.count == 1 {
                        throw failure
                    }
                }
            )
            Issue.record("Expected checkpoint store failure")
        } catch let caught as WorkCheckpointError {
            #expect(caught == failure)
        } catch {
            Issue.record("Expected WorkCheckpointError, got \(error)")
        }

        #expect(await checkpoints.values.count == 1)
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("Reviewed single writes emit durable checkpoint boundaries")
    func checkpointsSingleWrite() async throws {
        let fixture = await makeCoordinator()
        let itemID = UUID()
        let proposal = ProposedChange(
            id: itemID,
            track: makeEditableTrack(id: "MK1", genre: "Rock", year: 1969),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let checkpoints = CheckpointProbe()

        _ = try await fixture.coordinator.applyAcceptedChanges(
            [proposal],
            progressHandler: ignoreAcceptedChangeProgress,
            checkpoint: { checkpoint in
                let effects = await checkpointEffects(for: checkpoint, fixture: fixture)
                await checkpoints.append(checkpoint, effects: effects)
            }
        )

        let captured = await checkpoints.values
        let effects = await checkpoints.verifiedEffects
        #expect(captured.map(\.boundary) == [.beforeAttempt, .afterAttempt, .afterVerification])
        #expect(captured.map(\.states) == [
            [itemID: .attempting],
            [itemID: .attempted],
            [itemID: .outcome(.written)],
        ])
        #expect(effects.map(\.historyCount) == [1])
        #expect(effects.map(\.processingCount) == [1])
    }

    @Test("Unknown single-write outcomes remain at the attempted boundary")
    func unknownSingleWriteRemainsAttempted() async throws {
        let fixture = await makeCoordinator()
        let itemID = UUID()
        let proposal = ProposedChange(
            id: itemID,
            track: makeEditableTrack(id: "MK1", genre: "Rock", year: 1969),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let checkpoints = CheckpointProbe()
        await fixture.bridge.setCustomWriteError(
            AppleScriptOutcomeError(scriptName: "update_property", reason: "unverifiable response")
        )

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        let captured = await checkpoints.values
        #expect(captured.map(\.boundary) == [.beforeAttempt, .afterAttempt])
        #expect(captured.last?.states == [itemID: .attempted])
    }

    @Test("Single-write cancellation stops the reviewed write group")
    func cancellationStopsSingleWrites() async throws {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        let proposals = [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library"
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz"
            ),
        ]
        let checkpoints = CheckpointProbe()
        await fixture.bridge.setCustomWriteError(CancellationError())

        await #expect(throws: CancellationError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        let captured = await checkpoints.values
        #expect(captured.map(\.boundary) == [.beforeAttempt, .afterAttempt])
        #expect(captured.allSatisfy { Set($0.states.keys) == [proposals[0].id] })
    }

    @Test("Reviewed batch writes checkpoint all items atomically")
    func checkpointsBatchWrite() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let itemIDs = [UUID(), UUID()]
        let proposals = [
            ProposedChange(
                id: itemIDs[0],
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library"
            ),
            ProposedChange(
                id: itemIDs[1],
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz"
            ),
        ]
        let checkpoints = CheckpointProbe()

        _ = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreAcceptedChangeProgress,
            checkpoint: { checkpoint in
                let effects = await checkpointEffects(for: checkpoint, fixture: fixture)
                await checkpoints.append(checkpoint, effects: effects)
            }
        )

        let captured = await checkpoints.values
        let effects = await checkpoints.verifiedEffects
        #expect(captured.map(\.boundary) == [.beforeAttempt, .afterAttempt, .afterVerification])
        #expect(captured.map { Set($0.states.keys) } == [Set(itemIDs), Set(itemIDs), Set(itemIDs)])
        #expect(captured.last?.states == [
            itemIDs[0]: .outcome(.written),
            itemIDs[1]: .outcome(.written),
        ])
        #expect(effects.map(\.historyCount) == [2])
        #expect(effects.map(\.processingCount) == [2])
    }

    @Test("Partial batch verification records confirmed items")
    func recordsPartialBatch() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        await fixture.bridge.setBatchMutationLimit(1)
        let itemIDs = [UUID(), UUID()]
        let proposals = [
            ProposedChange(
                id: itemIDs[0],
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library"
            ),
            ProposedChange(
                id: itemIDs[1],
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz"
            ),
        ]
        let checkpoints = CheckpointProbe()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    let effects = await checkpointEffects(for: checkpoint, fixture: fixture)
                    await checkpoints.append(checkpoint, effects: effects)
                }
            )
        }

        let captured = await checkpoints.values
        let effects = await checkpoints.verifiedEffects
        #expect(captured.map(\.boundary) == [.beforeAttempt, .afterAttempt, .afterVerification])
        #expect(captured.last?.states == [itemIDs[0]: .outcome(.written)])
        let history = await fixture.undo.getHistory()
        #expect(history.map(\.trackID) == ["MK1"])
        #expect(history.map(\.changeType) == [.genreUpdate])
        let processingUpdates = await fixture.trackStore.processingUpdates
        #expect(processingUpdates.count == 1)
        #expect(processingUpdates.first?.id == "MK1")
        #expect(processingUpdates.first?.genreUpdated == true)
        #expect(processingUpdates.first?.yearUpdated == nil)
        #expect(effects.map(\.historyCount) == [1])
        #expect(effects.map(\.processingCount) == [1])
    }

    @Test("Single-write persistence failures remain at the attempted boundary")
    func singlePersistenceFailure() async throws {
        let fixture = await makeCoordinator()
        await fixture.trackStore.failProcessingUpdates()
        let itemID = UUID()
        let proposal = ProposedChange(
            id: itemID,
            track: makeEditableTrack(id: "MK1", genre: "Rock", year: 1969),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let checkpoints = CheckpointProbe()

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        #expect(await fixture.bridge.writtenProperties.count == 1)
        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt])
        #expect(await checkpoints.values.last?.states == [itemID: .attempted])
        #expect(await fixture.undo.getHistory().count == 1)
        #expect(await fixture.trackStore.processingUpdates.isEmpty)
    }

    @Test("Verified batch persistence failures keep every item attempted")
    func batchPersistenceFailure() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        await fixture.trackStore.failProcessingUpdates()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let itemIDs = [UUID(), UUID()]
        let proposals = [
            ProposedChange(
                id: itemIDs[0],
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library"
            ),
            ProposedChange(
                id: itemIDs[1],
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz"
            ),
        ]
        let checkpoints = CheckpointProbe()

        await #expect(throws: UpdateCoordinatorError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        #expect(await fixture.bridge.batchUpdates.count == 1)
        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt])
        #expect(await checkpoints.values.last?.states == [
            itemIDs[0]: .attempted,
            itemIDs[1]: .attempted,
        ])
        #expect(await fixture.undo.getHistory().count == 2)
        #expect(await fixture.trackStore.processingUpdates.isEmpty)
    }

    @Test("Partial-batch persistence failures do not publish written outcomes")
    func partialPersistenceFailure() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        await fixture.trackStore.failProcessingUpdates()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        await fixture.bridge.setBatchMutationLimit(1)
        let itemIDs = [UUID(), UUID()]
        let proposals = [
            ProposedChange(
                id: itemIDs[0],
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library"
            ),
            ProposedChange(
                id: itemIDs[1],
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz"
            ),
        ]
        let checkpoints = CheckpointProbe()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt])
        #expect(await checkpoints.values.last?.states == [
            itemIDs[0]: .attempted,
            itemIDs[1]: .attempted,
        ])
        #expect(await fixture.undo.getHistory().count == 1)
        #expect(await fixture.trackStore.processingUpdates.isEmpty)
    }

    private func checkpointEffects(
        for checkpoint: WorkCheckpoint,
        fixture: AcceptedApplyFixture
    ) async -> CheckpointEffects? {
        guard checkpoint.boundary == .afterVerification else { return nil }
        let historyCount = await fixture.undo.getHistory().count
        let processingCount = await fixture.trackStore.processingUpdates.count
        return CheckpointEffects(
            historyCount: historyCount,
            processingCount: processingCount
        )
    }

    private func storeFailure(for checkpoint: WorkCheckpoint) -> WorkCheckpointError {
        let startedAt = Date(timeIntervalSince1970: 100)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: startedAt,
            reason: "checkpoint-store-test"
        )
        let candidate = RunLifecycleSnapshot(
            runID: RunID(),
            requestID: RunRequestID(),
            trigger: .manualCheck,
            intent: .writeFixes,
            scope: scope,
            startedAt: startedAt,
            phase: .active(.writing)
        )
        return .store(CheckpointStoreFailure(
            checkpoint: checkpoint,
            candidate: candidate,
            durableSnapshot: candidate,
            isWriteAdjacent: false,
            reason: "record store unavailable"
        ))
    }
}
