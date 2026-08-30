import Foundation
import Testing
@testable import Core
@testable import Services

extension ApplyAcceptedTests {
    @Test("Accepted write succeeds and keeps undo evidence when effect delivery fails")
    func acceptedWriteSurvivesEffectFailure() async throws {
        let fixture = await makeCoordinator(hasEffectTargets: false)
        let track = makeEditableTrack(id: "T1", genre: "Rock", year: 1999)
        let change = ProposedChange(
            track: track,
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Metal",
            confidence: 90,
            source: "Library",
            isAccepted: true
        )

        let result = try await fixture.coordinator.applyAcceptedChanges(
            [change],
            progressHandler: ignoreAcceptedChangeProgress
        )

        #expect(result.entries.count == 1)
        #expect(await fixture.bridge.writtenProperties.count == 1)
        #expect(await fixture.undo.getHistory().count == 1)
        #expect(try await fixture.trackStore.pendingMirrorEffects().isEmpty == false)
    }

    @Test("Single-write finalization failures keep the written outcome")
    func singlePersistenceFailure() async throws {
        let fixture = await makeCoordinator()
        await fixture.trackStore.failAppliedUpdates()
        let track = makeEditableTrack(id: "MK1", genre: "Rock", year: 1969)
        await fixture.cache.storeAlbumYear(
            artist: track.artist,
            album: track.album,
            year: 1969,
            confidence: 80
        )
        await fixture.cache.setCachedAPIResult(CachedAPIResult(
            artist: track.artist,
            album: track.album,
            year: 1969,
            source: "musicbrainz",
            timestamp: .now,
            ttl: nil
        ))
        let itemID = UUID()
        let proposal = ProposedChange(
            id: itemID,
            track: track,
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
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.cache.getCachedAPIResult(
            artist: track.artist,
            album: track.album,
            source: "musicbrainz"
        ) == nil)
        #expect(await fixture.snapshot.wasCleared())
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
