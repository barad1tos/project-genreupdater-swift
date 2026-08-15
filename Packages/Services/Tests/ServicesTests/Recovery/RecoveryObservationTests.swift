import Core
import Foundation
import Testing
@testable import Services

@Suite("Recovery observation classification")
struct RecoveryObservationTests {
    @Test("observed intended value classifies written")
    func classifiesWritten() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        let observed = RecoveryObservation.outcome(for: item, observedValue: "Stoner Rock")

        #expect(observed.outcome == .written)
        #expect(observed.observedValue == "Stoner Rock")
    }

    @Test("observed prior value classifies failed without retry")
    func classifiesFailed() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        #expect(RecoveryObservation.outcome(for: item, observedValue: "Rock").outcome == .failed)
    }

    @Test("observed external value needs review and keeps the evidence")
    func classifiesExternalChange() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        let observed = RecoveryObservation.outcome(for: item, observedValue: "Jazz")

        #expect(observed.outcome == .needsReview)
        #expect(observed.observedValue == "Jazz")
        #expect(observed.detail == "Observed Music.app value: Jazz")
    }

    @Test("absent track needs review with a missing-track note")
    func classifiesAbsentTrack() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        let observed = RecoveryObservation.outcome(for: item, observedValue: nil)

        #expect(observed.outcome == .needsReview)
        #expect(observed.detail == "Track not found in Music.app")
    }

    @Test("empty observed value matches a nil prior value as failed")
    func treatsEmptyAsNilPrior() {
        let item = makeWorkItem(state: .attempted, oldValue: nil, newValue: "1999")

        #expect(RecoveryObservation.outcome(for: item, observedValue: "").outcome == .failed)
    }

    @Test("every change type observes its own AppleScript property")
    func mapsChangeTypesToProperties() {
        let expectations: [(ChangeType, AppleScriptTrackProperty)] = [
            (.genreUpdate, .genre),
            (.yearUpdate, .year),
            (.yearRevert, .year),
            (.trackCleaning, .name),
            (.albumCleaning, .album),
            (.artistRename, .artist),
        ]
        for (changeType, property) in expectations {
            #expect(AppleScriptTrackProperty(changeType: changeType) == property)
            #expect(UpdateCoordinator.appleScriptProperty(for: changeType) == property.rawValue)
        }
    }
}

@Suite("Recovery observation service")
struct RecoveryObservationServiceTests {
    @Test("observed live value classifies landed and externally changed items")
    func observesUncertainItems() async throws {
        let landed = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")
        let external = makeWorkItem(state: .attempting, oldValue: "Pop", newValue: "Synthpop")
        let client = MockAppleScriptClient()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", genre: "Stoner Rock"),
        ])
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [landed, external])

        #expect(outcomes[landed.id]?.outcome == .written)
        #expect(outcomes[external.id]?.outcome == .needsReview)
        #expect(outcomes[external.id]?.observedValue == "Stoner Rock")
    }

    @Test("two properties of one track classify independently")
    func classifiesTwoPropertiesOfOneTrack() async throws {
        let genreItem = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")
        let yearItem = makeWorkItem(
            state: .attempted,
            changeType: .yearUpdate,
            oldValue: "1999",
            newValue: "2001"
        )
        let client = MockAppleScriptClient()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", genre: "Stoner Rock", year: 1999),
        ])
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [genreItem, yearItem])

        #expect(outcomes[genreItem.id]?.outcome == .written)
        #expect(outcomes[yearItem.id]?.outcome == .failed)
    }

    @Test("partial coupled artist writes require review")
    func partialCoupledArtistWriteNeedsReview() async throws {
        let albumArtistChange = AlbumArtistChange(oldValue: "Massive", newValue: "Massive Attack")
        let item = makeWorkItem(
            state: .attempted,
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            albumArtistChange: albumArtistChange,
            writeChange: WorkChange(
                changeType: .artistRename,
                oldValue: "Massive",
                newValue: "Massive Attack",
                confidence: 92,
                source: "Artist mappings",
                albumArtistChange: albumArtistChange
            )
        )
        let client = MockAppleScriptClient()
        await client.setFetchedTracks([
            observedTrack(
                id: "persistent-1",
                artist: "Massive Attack",
                albumArtist: "Massive"
            ),
        ])

        let outcomes = try await RecoveryObservationService(scriptClient: client).observeOutcomes(for: [item])

        #expect(outcomes[item.id]?.outcome == .needsReview)
        #expect(outcomes[item.id]?.observedValue == "Massive Attack (album artist: Massive)")
    }

    @Test("coupled artist recovery requires both physical values")
    func classifiesCoupledArtistOutcome() async throws {
        let albumArtistChange = AlbumArtistChange(oldValue: "Massive", newValue: "Massive Attack")
        let item = makeWorkItem(
            state: .attempted,
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            albumArtistChange: albumArtistChange,
            writeChange: WorkChange(
                changeType: .artistRename,
                oldValue: "Massive",
                newValue: "Massive Attack",
                confidence: 92,
                source: "Artist mappings",
                albumArtistChange: albumArtistChange
            )
        )
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", artist: "Massive Attack", albumArtist: "Massive Attack"),
        ])
        #expect(try await service.observeOutcomes(for: [item])[item.id]?.outcome == .written)

        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", artist: "Massive", albumArtist: "Massive"),
        ])
        #expect(try await service.observeOutcomes(for: [item])[item.id]?.outcome == .failed)
    }

    @Test("prepared items skip without observation")
    func skipsPreparedWithoutFetch() async throws {
        let prepared = makeWorkItem(state: .prepared)
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [prepared])

        #expect(outcomes[prepared.id]?.outcome == .skipped)
        #expect(await client.fetchTracksByIDsCalls().isEmpty)
    }

    @Test("terminal items are not observed")
    func ignoresTerminalItems() async throws {
        let terminal = makeWorkItem(state: .outcome(.written))
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [terminal])

        #expect(outcomes.isEmpty)
    }

    @Test("fetch failure propagates and blocks clearance")
    func propagatesFetchFailure() async {
        let attempted = makeWorkItem(state: .attempted)
        let client = MockAppleScriptClient()
        await client.setFetchThrowMode(true)
        let service = RecoveryObservationService(scriptClient: client)

        await #expect(throws: MockScriptError.self) {
            _ = try await service.observeOutcomes(for: [attempted])
        }
    }

    @Test("a fully deleted selection classifies as reviewable, not blocked")
    func classifiesDeletedSelection() async throws {
        let attempted = makeWorkItem(state: .attempted)
        let client = MockAppleScriptClient()
        let service = RecoveryObservationService(scriptClient: client)

        let outcomes = try await service.observeOutcomes(for: [attempted])

        #expect(outcomes[attempted.id]?.outcome == .needsReview)
        #expect(outcomes[attempted.id]?.detail == "Track not found in Music.app")
    }
}

private func observedTrack(
    id: String,
    genre: String = "Rock",
    year: Int? = nil,
    artist: String = "Artist",
    albumArtist: String? = nil
) -> Track {
    Track(
        id: id,
        name: "Track",
        artist: artist,
        album: "Album",
        genre: genre,
        year: year,
        albumArtist: albumArtist
    )
}

@Suite("Work ledger observed outcomes")
struct ObservedOutcomeLedgerTests {
    @Test("observed outcomes close every open item and keep the evidence")
    func closesOpenItems() throws {
        let attempted = makeWorkItem(state: .attempted)
        let prepared = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([attempted, prepared])

        let closed = try ledger.applyingObservedOutcomes([
            attempted.id: ObservedWorkOutcome(outcome: .written, observedValue: "Metal"),
            prepared.id: ObservedWorkOutcome(outcome: .skipped, observedValue: nil),
        ])

        #expect(closed.items.map(\.state) == [.outcome(.written), .outcome(.skipped)])
        #expect(closed.items.first?.detail == "Verified in Music.app: Metal")
        #expect(!closed.hasOpenItems)
        #expect(!closed.hasUncertainty)
    }

    @Test("observed written closes an attempting item through the attempt boundary")
    func promotesAttemptingToWritten() throws {
        let attempting = makeWorkItem(state: .attempting)
        let ledger = WorkLedger([attempting])

        let closed = try ledger.applyingObservedOutcomes([
            attempting.id: ObservedWorkOutcome(outcome: .written, observedValue: "Metal"),
        ])

        #expect(closed.items.map(\.state) == [.outcome(.written)])
    }

    @Test("missing observed outcome for an open item is rejected")
    func rejectsIncompleteCoverage() {
        let attempted = makeWorkItem(state: .attempted)
        let prepared = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([attempted, prepared])

        #expect(throws: WorkCheckpointError.self) {
            _ = try ledger.applyingObservedOutcomes([
                attempted.id: ObservedWorkOutcome(outcome: .written, observedValue: nil),
            ])
        }
    }

    @Test("a written observation for a never-dispatched item is rejected")
    func rejectsPreparedWritten() {
        let prepared = makeWorkItem(state: .prepared)
        let ledger = WorkLedger([prepared])

        #expect(throws: WorkCheckpointError.self) {
            _ = try ledger.applyingObservedOutcomes([
                prepared.id: ObservedWorkOutcome(outcome: .written, observedValue: "Metal"),
            ])
        }
    }

    @Test("terminal items are left untouched by observed outcomes")
    func preservesTerminalItems() throws {
        let written = makeWorkItem(state: .outcome(.failed))
        let attempted = makeWorkItem(state: .attempted)
        let ledger = WorkLedger([written, attempted])

        let closed = try ledger.applyingObservedOutcomes([
            attempted.id: ObservedWorkOutcome(outcome: .noFixNeeded, observedValue: nil),
        ])

        #expect(closed.items.map(\.state) == [.outcome(.failed), .outcome(.noFixNeeded)])
    }
}
