import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator — durable write identity")
struct ApplyIdentityTests {
    @Test("Partially applied reviewed batches report the canonical database ID")
    func partialBatchUsesDatabaseID() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeEditableTrack(id: "MK1", genre: "Rock", year: 1999)
        let appleScriptTrack = makeEditableTrack(id: "AS1", genre: "Rock", year: 1999)
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )
        let fixture = await makeCoordinator(
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: true,
                maxBatchUpdateSize: 5
            ),
            idMapper: mapper
        )
        await fixture.bridge.setBatchMutationLimit(1)
        await fixture.bridge.setSingleWriteResult(.noChange)
        await fixture.bridge.setFetchedTracks([appleScriptTrack])

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                acceptedProposals(for: musicKitTrack),
                progressHandler: ignoreAcceptedChangeProgress
            )
            Issue.record("Expected a partially applied batch outcome")
        } catch let error as PartialWriteError {
            #expect(error.appliedTrackIDs == [appleScriptTrack.id])
            #expect(error.underlyingError is AppleScriptOutcomeError)
        } catch {
            Issue.record("Expected PartialWriteError, got \(error)")
        }

        let batches = await fixture.bridge.batchUpdates
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.databaseID.rawValue) == ["AS1", "AS1"])
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }
}
