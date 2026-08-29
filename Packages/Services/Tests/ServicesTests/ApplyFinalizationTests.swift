import Foundation
import Testing
@testable import Core
@testable import Services

extension ApplyAcceptedTests {
    @Test("Single-write finalization failures keep the written outcome")
    func singlePersistenceFailure() async throws {
        let fixture = await makeCoordinator()
        await fixture.trackStore.failAppliedUpdates()
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
        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt, .afterVerification])
        #expect(await checkpoints.values.last?.states == [itemID: .outcome(.written)])
        #expect(await fixture.undo.getHistory().isEmpty)
        #expect(await fixture.trackStore.appliedUpdates.isEmpty)
    }

    @Test("Verified batch finalization failures keep written outcomes")
    func batchPersistenceFailure() async throws {
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            )
        )
        await fixture.trackStore.failAppliedUpdates()
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
        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt, .afterVerification])
        #expect(await checkpoints.values.last?.states == [
            itemIDs[0]: .outcome(.written),
            itemIDs[1]: .outcome(.written),
        ])
        #expect(await fixture.undo.getHistory().isEmpty)
        #expect(await fixture.trackStore.appliedUpdates.isEmpty)
    }

    @Test("Partial-batch finalization failures keep confirmed outcomes")
    func partialPersistenceFailure() async throws {
        let (fixture, itemIDs, proposals) = await makePartialBatch()
        await fixture.trackStore.failAppliedUpdates()
        let checkpoints = CheckpointProbe()

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreAcceptedChangeProgress,
                checkpoint: { await checkpoints.append($0) }
            )
            Issue.record("Expected an unknown batch outcome")
        } catch let outcome as AppleScriptOutcomeError {
            #expect(outcome.reason.contains("write finalization failed for 1 applied writes"))
        } catch {
            Issue.record("Expected AppleScriptOutcomeError, got \(error)")
        }

        #expect(await checkpoints.values.map(\.boundary) == [.beforeAttempt, .afterAttempt, .afterVerification])
        #expect(await checkpoints.values.last?.states == [
            itemIDs[0]: .outcome(.written),
        ])
        #expect(await fixture.undo.getHistory().isEmpty)
        #expect(await fixture.trackStore.appliedUpdates.isEmpty)
    }
}
