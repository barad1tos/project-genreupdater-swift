import Core
import Foundation
import Testing
@testable import Services

@Suite("Write attempt hooks")
struct WriteHookTests {
    @Test("Default attempt hooks preserve plain write uncertainty")
    func keepsHookUncertainty() async {
        let track = makeTrack(id: "T1")
        let client = OutcomeScriptClient(tracks: [track], failure: .plain)
        let coordinator = makeCoordinator(client)
        let checkpoints = CheckpointProbe()

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.applyChangeOutcome(
                makeGenreChange(track),
                isReviewedChange: false,
                checkpoint: { await checkpoints.append($0) }
            )
        }

        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt])
    }

    @Test("Plain write errors remain unknown without a checkpoint sink")
    func plainWriteStaysUnknown() async {
        let track = makeTrack(id: "T1")
        let client = OutcomeScriptClient(tracks: [track], failure: .plain)
        let coordinator = makeCoordinator(client)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.applyChangeOutcome(
                makeGenreChange(track),
                isReviewedChange: false
            )
        }

        #expect(await client.writeAttempts == 1)
    }

    @Test("Plain batch errors remain unknown without falling back to single writes")
    func plainBatchStaysUnknown() async {
        let track = makeTrack(id: "T1")
        let client = OutcomeScriptClient(tracks: [track], failure: .plain)
        let coordinator = makeCoordinator(
            client,
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await coordinator.applyReviewedChangeGroup(
                [makeGenreChange(track), makeYearChange(track)],
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions
            )
        }

        #expect(await client.batchAttempts == 1)
        #expect(await client.writeAttempts == 0)
    }

    @Test("Default attempt hooks retain physical completion when checkpoint storage fails")
    func keepsLegacyCompletion() async throws {
        let track = makeTrack(id: "T1")
        let change = makeGenreChange(track)
        let completion = ScriptCompletion()
        let client = OutcomeScriptClient(tracks: [track], completion: completion)
        let coordinator = makeCoordinator(client)
        let failure = try makeStoreFailure(itemIDs: [change.id])

        await expectStoredCompletion(completion) {
            _ = try await coordinator.applyChangeOutcome(
                change,
                isReviewedChange: false,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterAttempt {
                        throw WorkCheckpointError.store(failure)
                    }
                }
            )
        }
    }

    @Test("Default batch hooks retain physical completion when checkpoint storage fails")
    func keepsBatchCompletion() async throws {
        let tracks = [
            makeTrack(id: "T1", year: 2000),
            makeTrack(id: "T2", year: 2000)
        ]
        let changes = tracks.map(makeYearChange)
        let completion = ScriptCompletion()
        let client = OutcomeScriptClient(tracks: tracks, completion: completion)
        let coordinator = makeCoordinator(
            client,
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        let itemIDs = changes.map(\.id)
        let failure = try makeStoreFailure(itemIDs: itemIDs)
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        await expectStoredCompletion(completion) {
            _ = try await coordinator.applyReviewedChangeGroup(
                changes,
                failedTrackIDs: &failedTrackIDs,
                errorDescriptions: &errorDescriptions,
                checkpoint: { checkpoint in
                    if checkpoint.boundary == .afterAttempt {
                        throw WorkCheckpointError.store(failure)
                    }
                }
            )
        }

        #expect(await client.batchAttempts == 1)
        #expect(await client.writeAttempts == 0)
    }
}
