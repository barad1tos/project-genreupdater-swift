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

    @Test("Single after-attempt checkpoint failure clears write caches")
    func singleFailureClearsCaches() async throws {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        try await seedCaches(for: track, fixture: fixture)
        let proposal = ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let failure = storeFailure(for: .afterAttempt([proposal.id]))

        await #expect(throws: WorkCheckpointError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterAttempt {
                        throw failure
                    }
                }
            )
        }

        await expectCachesCleared(for: track, fixture: fixture)
    }

    @Test("Preflight no-op clears caches before terminal checkpoint")
    func noOpCacheOrder() async throws {
        let fixture = await makeCoordinator()
        let itemID = UUID()
        var track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        track.yearBeforeMGU = 1969
        try await seedCaches(for: track, fixture: fixture)
        let proposal = ProposedChange(
            id: itemID,
            track: track,
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )
        let failure = storeFailure(for: .afterVerification([itemID: .noFixNeeded]))

        await expectCheckpointFailure(failure) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterVerification {
                        throw failure
                    }
                }
            )
        }

        #expect(await fixture.bridge.writtenProperties.isEmpty)
        await expectCachesCleared(for: track, fixture: fixture)
    }

    @Test("Dispatched no-change clears caches before terminal checkpoint")
    func noChangeCache() async throws {
        let fixture = await makeCoordinator()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        try await seedCaches(for: track, fixture: fixture)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let proposal = ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let failure = storeFailure(for: .afterVerification([proposal.id: .noFixNeeded]))

        await expectCheckpointFailure(failure) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterVerification {
                        throw failure
                    }
                }
            )
        }

        #expect(await fixture.bridge.writtenProperties.count == 1)
        await expectCachesCleared(for: track, fixture: fixture)
    }

    @Test("Preparation dual failure preserves checkpoint safety error")
    func prepareDualFailure() async {
        let fixture = await makeCoordinator()
        let proposal = ProposedChange(
            track: Track(
                id: "MK1",
                name: "Come Together",
                artist: "Beatles",
                album: "Abbey Road",
                genre: "Rock",
                year: 1969,
                trackStatus: "no longer available"
            ),
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
            confidence: 95,
            source: "MusicBrainz",
            isAccepted: true
        )
        let failure = storeFailure(for: .afterVerification([proposal.id: .failed]))

        await expectCheckpointFailure(failure) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterVerification {
                        throw failure
                    }
                }
            )
        }

        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("Pre-dispatch dual failure preserves checkpoint safety error")
    func dispatchDualFailure() async {
        let fixture = await makeCoordinator()
        await fixture.bridge.setThrowMode(true)
        let proposal = ProposedChange(
            track: makeEditableTrack(id: "MK1", genre: "Rock", year: 1969),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let checkpoints = CheckpointProbe()
        let failure = storeFailure(for: .afterVerification([proposal.id: .failed]))

        await expectCheckpointFailure(failure) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [proposal],
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    await checkpoints.append(checkpoint)
                    if checkpoint.boundary == .afterVerification {
                        throw failure
                    }
                }
            )
        }

        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterVerification])
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("Batch after-attempt checkpoint failure clears write caches")
    func batchFailureClearsCaches() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        try await seedCaches(for: track, fixture: fixture)
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
        let failure = storeFailure(for: .afterAttempt(proposals.map(\.id)))

        await #expect(throws: WorkCheckpointError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterAttempt {
                        throw failure
                    }
                }
            )
        }

        await expectCachesCleared(for: track, fixture: fixture)
    }

    @Test("Out-of-scope writes checkpoint a skipped outcome")
    func skippedWriteCheckpoints() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(testArtists: ["In Flames"])
        )
        let proposal = ProposedChange(
            track: makeEditableTrack(id: "MK1", genre: "Rock", year: 1969),
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Electronic",
            confidence: 80,
            source: "Library",
            isAccepted: true
        )
        let checkpoints = CheckpointProbe()

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [proposal],
            progressHandler: ignoreAcceptedChangeProgress,
            checkpoint: { await checkpoints.append($0) }
        )

        #expect(result.entries.isEmpty)
        #expect(result.failedTrackIDs.isEmpty)
        #expect(await checkpoints.values.map(\.boundary) == [.afterVerification])
        #expect(await checkpoints.values.first?.states == [proposal.id: .outcome(.skipped)])
    }

    @Test("Preparation failures checkpoint a failed outcome")
    func failedWriteCheckpoints() async throws {
        let fixture = await makeCoordinator()
        let proposal = ProposedChange(
            track: Track(
                id: "MK1",
                name: "Come Together",
                artist: "Beatles",
                album: "Abbey Road",
                genre: "Rock",
                year: 1969,
                trackStatus: "no longer available"
            ),
            changeType: .yearUpdate,
            oldValue: "1969",
            newValue: "1970",
            confidence: 95,
            source: "MusicBrainz",
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

        #expect(await checkpoints.values.map(\.boundary) == [.afterVerification])
        #expect(await checkpoints.values.first?.states == [proposal.id: .outcome(.failed)])
        #expect(await fixture.bridge.writtenProperties.isEmpty)
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

    private func seedCaches(for track: Track, fixture: AcceptedApplyFixture) async throws {
        let year = try #require(track.year)
        await fixture.cache.storeAlbumYear(
            artist: track.artist,
            album: track.album,
            year: year,
            confidence: 80
        )
        await fixture.cache.setCachedAPIResult(CachedAPIResult(
            artist: track.artist,
            album: track.album,
            year: year,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        ))
    }

    private func expectCachesCleared(for track: Track, fixture: AcceptedApplyFixture) async {
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.cache.getCachedAPIResult(
            artist: track.artist,
            album: track.album,
            source: "musicbrainz"
        ) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    private func expectCheckpointFailure(
        _ expected: WorkCheckpointError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected checkpoint failure")
        } catch let caught as WorkCheckpointError {
            #expect(caught == expected)
        } catch {
            Issue.record("Expected WorkCheckpointError, got \(error)")
        }
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
