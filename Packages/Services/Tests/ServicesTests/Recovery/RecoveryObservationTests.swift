import Core
import Foundation
import Testing
@testable import Services

@Suite("Recovery observation classification")
struct RecoveryObservationTests {
    @Test("observed intended value classifies written")
    func classifiesWritten() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", genre: "Stoner Rock")
        )

        #expect(observed.outcome == .written)
        #expect(observed.observedValue == "Stoner Rock")
    }

    @Test("observed prior value classifies failed without retry")
    func classifiesFailed() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", genre: "Rock")
        )

        #expect(observed.outcome == .failed)
    }

    @Test("observed external value needs review and keeps the evidence")
    func classifiesExternalChange() {
        let item = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", genre: "Jazz")
        )

        #expect(observed.outcome == .needsReview)
        #expect(observed.observedValue == "Jazz")
        #expect(observed.detail == "Observed Music.app value: Jazz")
    }

    @Test("empty observed value matches a nil prior value as failed")
    func treatsEmptyAsNilPrior() {
        let item = makeWorkItem(state: .attempted, oldValue: nil, newValue: "1999")

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", genre: "")
        )

        #expect(observed.outcome == .failed)
    }

    @Test("missing Music.app year verifies a clear write")
    func classifiesYearClear() {
        let item = makeWorkItem(
            state: .attempted,
            changeType: .yearRevert,
            oldValue: "2019",
            newValue: String(MusicAppYear.missingValue)
        )

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", year: nil)
        )

        #expect(observed.outcome == .written)
        #expect(observed.observedValue?.isEmpty == true)
    }

    @Test("unchanged year proves a clear write did not land")
    func classifiesMissedClear() {
        let item = makeWorkItem(
            state: .attempted,
            changeType: .yearRevert,
            oldValue: "2019",
            newValue: String(MusicAppYear.missingValue)
        )

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", year: 2019)
        )

        #expect(observed.outcome == .failed)
    }

    @Test("external year after a clear attempt requires review")
    func classifiesConflictingYear() {
        let item = makeWorkItem(
            state: .attempted,
            changeType: .yearRevert,
            oldValue: "2019",
            newValue: String(MusicAppYear.missingValue)
        )

        let observed = RecoveryObservation.outcome(
            for: item,
            observedTrack: observedTrack(id: "persistent-1", year: 2020)
        )

        #expect(observed.outcome == .needsReview)
        #expect(observed.observedValue == "2020")
    }

    @Test("every change type observes its own AppleScript property")
    func mapsChangeTypesToProperties() {
        let expectations: [(ChangeType, MusicTrackProperty)] = [
            (.genreUpdate, .genre),
            (.yearUpdate, .year),
            (.yearRevert, .year),
            (.trackCleaning, .name),
            (.albumCleaning, .album),
            (.artistRename, .artist),
        ]
        for (changeType, property) in expectations {
            #expect(MusicTrackProperty(changeType: changeType) == property)
        }
    }
}

@Suite("Recovery observation service")
struct RecoveryObservationServiceTests {
    @Test("observed live value classifies landed and externally changed items")
    func observesUncertainItems() async throws {
        let landed = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")
        let external = makeWorkItem(state: .attempting, oldValue: "Pop", newValue: "Synthpop")
        let client = MusicAppTestAccess()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", genre: "Stoner Rock"),
        ])
        let service = RecoveryObservationService(verifier: client)

        let outcomes = try await service.observeOutcomes(for: [landed, external])

        #expect(outcomes[landed.id]?.outcome == .written)
        #expect(outcomes[external.id]?.outcome == .needsReview)
        #expect(outcomes[external.id]?.observedValue == "Stoner Rock")
        #expect(try await client.fetchMetadataCalls() == [[#require(MusicDatabaseTrackID(rawValue: "persistent-1"))]])
    }

    @Test("reused database identity cannot clear recovery")
    func reusedDatabaseIDNeedsReview() async throws {
        let attempted = makeWorkItem(state: .attempted, oldValue: "Rock", newValue: "Stoner Rock")
        let client = MusicAppTestAccess()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", name: "Replacement Track", genre: "Stoner Rock"),
        ])
        let service = RecoveryObservationService(verifier: client)

        let outcome = try #require(try await service.observeOutcomes(for: [attempted])[attempted.id])

        #expect(outcome.outcome == .needsReview)
        #expect(outcome.detail == "Music.app track identity changed since the write was planned")
    }

    @Test("reused database identity with another album artist cannot clear recovery")
    func reusedDatabaseIDByAlbumArtistNeedsReview() async throws {
        let change = WorkChange(
            changeType: .genreUpdate,
            oldValue: "Rock",
            newValue: "Stoner Rock",
            confidence: 92,
            source: "MusicBrainz"
        )
        let attempted = RunWorkItem(
            id: UUID(),
            target: .track(FixPlanItemIdentity(
                readID: "music-kit-1",
                appleScriptID: "persistent-1",
                artist: "Artist",
                album: "Album",
                trackName: "Track",
                albumArtist: "Artist"
            )),
            change: change,
            state: .attempted
        )
        let client = MusicAppTestAccess()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", genre: "Stoner Rock", albumArtist: "Compilation Artist"),
        ])
        let service = RecoveryObservationService(verifier: client)

        let outcome = try #require(try await service.observeOutcomes(for: [attempted])[attempted.id])

        #expect(outcome.outcome == .needsReview)
        #expect(outcome.detail == "Music.app track identity changed since the write was planned")
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
        let client = MusicAppTestAccess()
        await client.setFetchedTracks([
            observedTrack(id: "persistent-1", genre: "Stoner Rock", year: 1999),
        ])
        let service = RecoveryObservationService(verifier: client)

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
            source: "Artist mappings",
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
        let client = MusicAppTestAccess()
        await client.setFetchedTracks([
            observedTrack(
                id: "persistent-1",
                artist: "Massive Attack",
                albumArtist: "Massive"
            ),
        ])

        let outcomes = try await RecoveryObservationService(verifier: client).observeOutcomes(for: [item])

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
            source: "Artist mappings",
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
        let client = MusicAppTestAccess()
        let service = RecoveryObservationService(verifier: client)

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
        let client = MusicAppTestAccess()
        let service = RecoveryObservationService(verifier: client)

        let outcomes = try await service.observeOutcomes(for: [prepared])

        #expect(outcomes[prepared.id]?.outcome == .skipped)
        #expect(await client.fetchMetadataCalls().isEmpty)
    }

    @Test("terminal items are not observed")
    func ignoresTerminalItems() async throws {
        let terminal = makeWorkItem(state: .outcome(.written))
        let client = MusicAppTestAccess()
        let service = RecoveryObservationService(verifier: client)

        let outcomes = try await service.observeOutcomes(for: [terminal])

        #expect(outcomes.isEmpty)
    }

    @Test("fetch failure propagates and blocks clearance")
    func propagatesFetchFailure() async {
        let attempted = makeWorkItem(state: .attempted)
        let client = MusicAppTestAccess()
        await client.setFetchThrowMode(true)
        let service = RecoveryObservationService(verifier: client)

        await #expect(throws: MockScriptError.self) {
            _ = try await service.observeOutcomes(for: [attempted])
        }
    }

    @Test("a fully deleted selection classifies as reviewable, not blocked")
    func classifiesDeletedSelection() async throws {
        let attempted = makeWorkItem(state: .attempted)
        let client = MusicAppTestAccess()
        let service = RecoveryObservationService(verifier: client)

        let outcomes = try await service.observeOutcomes(for: [attempted])

        #expect(outcomes[attempted.id]?.outcome == .needsReview)
        #expect(outcomes[attempted.id]?.detail == "Track not found in Music.app")
    }
}

private func observedTrack(
    id: String,
    name: String = "Track",
    genre: String = "Rock",
    year: Int? = nil,
    artist: String = "Artist",
    albumArtist: String? = nil
) -> Track {
    Track(
        id: id,
        name: name,
        artist: artist,
        album: "Album",
        genre: genre,
        year: year,
        albumArtist: albumArtist,
        appleScriptID: id
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
