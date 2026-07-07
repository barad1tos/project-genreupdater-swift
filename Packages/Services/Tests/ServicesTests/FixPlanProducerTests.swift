import Core
import Foundation
import Services
import Testing

@Suite("FixPlanProducer")
struct FixPlanProducerTests {
    private let sourceRunID = RunID()
    private let producedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("scoping skips out-of-scope artists before determination")
    func scopeFiltersBeforeDetermination() async throws {
        let inScope = track("IN", artist: "Aphex Twin")
        let outOfScope = track("OUT", artist: "Boards of Canada")
        let spy = FixPlanProducerSpy(
            tracks: [inScope, outOfScope],
            outcomes: ["IN": .changes([proposal(for: inScope)])]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: ["aphex twin"], knownTrackCount: 2),
            options: UpdateOptions(minConfidence: 60)
        )

        #expect(production.producedPlan)
        #expect(production.proposalCount == 1)
        #expect(await spy.albumContextInputs() == [["IN"]])
        #expect(await spy.determinationCalls().map(\.trackID) == ["IN"])
    }

    @Test("album context and artist groups are passed into determination")
    func passesAlbumAndArtistContext() async throws {
        let first = track("T1", artist: "Artist", album: "First")
        let second = track("T2", artist: "artist", album: "Second")
        let third = track("T3", artist: "Other", album: "First")
        let spy = FixPlanProducerSpy(
            tracks: [first, second, third],
            albumContextIDs: ["T1": ["T1", "T3"], "T2": ["T2"], "T3": ["T1", "T3"]]
        )

        _ = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 3),
            options: UpdateOptions(updateGenre: false, updateYear: true, minConfidence: 70)
        )

        let calls = await spy.determinationCalls()
        #expect(calls.map(\.trackID) == ["T1", "T2", "T3"])
        #expect(calls[0].albumTrackIDs == ["T1", "T3"])
        #expect(calls[0].artistTrackIDs == ["T1", "T2"])
        #expect(calls[0].updateGenre == false)
        #expect(calls[0].updateYear == true)
        #expect(calls[0].minConfidence == 70)
        #expect(calls[2].artistTrackIDs == ["T3"])
    }

    @Test("write eligibility errors skip tracks and continue")
    func skipsEligibilityErrors() async throws {
        let blocked = track("BLOCKED")
        let missingID = track("MISSING")
        let valid = track("VALID")
        let spy = FixPlanProducerSpy(
            tracks: [blocked, missingID, valid],
            outcomes: [
                "BLOCKED": .trackNotEditable,
                "MISSING": .missingAppleScriptID,
                "VALID": .changes([proposal(for: valid)]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 3),
            options: UpdateOptions(minConfidence: 60)
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(production.proposalCount == 1)
        #expect(saved.plan.items.map(\.identity.readID) == ["VALID"])
        #expect(await spy.determinationCalls().map(\.trackID) == ["BLOCKED", "MISSING", "VALID"])
    }

    @Test("non eligibility errors propagate without saving")
    func propagatesOtherErrors() async {
        let failing = track("FAIL")
        let spy = FixPlanProducerSpy(
            tracks: [failing],
            outcomes: ["FAIL": .failure]
        )

        await #expect(throws: ProducerTestError.intentional) {
            _ = try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: scope(requestedTestArtists: [], knownTrackCount: 1),
                options: UpdateOptions()
            )
        }
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("confidence filter excludes below-threshold proposals")
    func filtersByConfidence() async throws {
        let weak = track("WEAK")
        let strong = track("STRONG")
        let spy = FixPlanProducerSpy(
            tracks: [weak, strong],
            outcomes: [
                "WEAK": .changes([proposal(for: weak, confidence: 59)]),
                "STRONG": .changes([proposal(for: strong, confidence: 60)]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 2),
            options: UpdateOptions(minConfidence: 60)
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(production.proposalCount == 1)
        #expect(saved.plan.items.map(\.identity.readID) == ["STRONG"])
    }

    @Test("saved plan carries source scope configuration order and initial decision")
    func savesPlanAndInitialDecision() async throws {
        let first = track("A")
        let second = track("B")
        let currentScope = scope(requestedTestArtists: [], knownTrackCount: 2)
        let options = UpdateOptions(updateGenre: true, updateYear: false, minConfidence: 60)
        let firstProposal = proposal(for: first, confidence: 95)
        let secondProposal = proposal(for: second, confidence: 96)
        let spy = FixPlanProducerSpy(
            tracks: [first, second],
            outcomes: [
                "A": .changes([firstProposal]),
                "B": .changes([secondProposal]),
            ]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: currentScope,
            options: options
        )

        let saved = try #require(await spy.savedPlans().first)
        #expect(production.planID == saved.plan.id)
        #expect(saved.plan.sourceRunID == sourceRunID)
        #expect(saved.plan.scope == currentScope)
        #expect(saved.plan.configuration.capturedAt == producedAt)
        #expect(saved.plan.configuration.fingerprint == FixPlanConfigurationSnapshot
            .capture(options: options, capturedAt: producedAt)
            .fingerprint)
        #expect(saved.plan.items.map(\.id) == [firstProposal.id, secondProposal.id])
        #expect(saved.decision.planID == saved.plan.id)
        #expect(saved.decision.planRevision == .initial)
        #expect(saved.decision.revision == .initial)
        #expect(saved.decision.decidedAt == producedAt)
        #expect(saved.decision.itemDecisions.map(\.verdict) == [.accepted, .accepted])
        #expect(saved.decision.itemDecisions.map(\.itemID) == saved.plan.items.map(\.id))
    }

    @Test("empty proposals return empty production and do not save")
    func emptyDoesNotSave() async throws {
        let spy = FixPlanProducerSpy(
            tracks: [track("EMPTY")],
            outcomes: ["EMPTY": .changes([])]
        )

        let production = try await makeProducer(spy).producePlan(
            sourceRunID: sourceRunID,
            scope: scope(requestedTestArtists: [], knownTrackCount: 1),
            options: UpdateOptions()
        )

        #expect(production == .empty)
        #expect(await spy.savedPlans().isEmpty)
    }

    @Test("cancellation propagates")
    func propagatesCancellation() async {
        let cancelled = track("CANCEL")
        let spy = FixPlanProducerSpy(
            tracks: [cancelled],
            outcomes: ["CANCEL": .cancellation]
        )

        await #expect(throws: CancellationError.self) {
            _ = try await makeProducer(spy).producePlan(
                sourceRunID: sourceRunID,
                scope: scope(requestedTestArtists: [], knownTrackCount: 1),
                options: UpdateOptions()
            )
        }
    }

    private func makeProducer(_ spy: FixPlanProducerSpy) -> FixPlanProducer {
        FixPlanProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { await spy.loadTracks() },
            albumContextTracksByTrackID: { await spy.albumContextTracksByTrackID(for: $0) },
            determineTrackChanges: {
                try await spy.determineTrackChanges(
                    track: $0,
                    albumTracks: $1,
                    artistTracks: $2,
                    options: $3
                )
            },
            savePlan: { await spy.savePlan($0, decision: $1) },
            now: { self.producedAt }
        ))
    }

    private func scope(requestedTestArtists: [String], knownTrackCount: Int?) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot.capture(
            requestedTestArtists: requestedTestArtists,
            knownTrackCount: knownTrackCount,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "unit-test"
        )
    }
}

private actor FixPlanProducerSpy {
    private let tracks: [Track]
    private let albumContextIDs: [String: [String]]
    private let outcomes: [String: DeterminationOutcome]
    private var albumContextInputIDs: [[String]] = []
    private var calls: [DeterminationCall] = []
    private var saved: [(plan: FixPlan, decision: FixPlanReviewDecision)] = []

    init(
        tracks: [Track],
        albumContextIDs: [String: [String]] = [:],
        outcomes: [String: DeterminationOutcome] = [:]
    ) {
        self.tracks = tracks
        self.albumContextIDs = albumContextIDs
        self.outcomes = outcomes
    }

    func loadTracks() -> [Track] {
        tracks
    }

    func albumContextTracksByTrackID(for tracks: [Track]) -> [String: [Track]] {
        albumContextInputIDs.append(tracks.map(\.id))
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: tracks.map { track in
            let contextIDs = albumContextIDs[track.id] ?? [track.id]
            let contextTracks = contextIDs.compactMap { tracksByID[$0] }
            return (track.id, contextTracks)
        })
    }

    func determineTrackChanges(
        track: Track,
        albumTracks: [Track],
        artistTracks: [Track],
        options: UpdateOptions
    ) throws -> [ProposedChange] {
        calls.append(DeterminationCall(
            trackID: track.id,
            albumTrackIDs: albumTracks.map(\.id),
            artistTrackIDs: artistTracks.map(\.id),
            updateGenre: options.updateGenre,
            updateYear: options.updateYear,
            minConfidence: options.minConfidence
        ))

        switch outcomes[track.id] ?? .changes([]) {
        case let .changes(changes):
            return changes
        case .trackNotEditable:
            throw UpdateCoordinatorError.trackNotEditable(trackID: track.id)
        case .missingAppleScriptID:
            throw UpdateCoordinatorError.missingAppleScriptID(trackID: track.id)
        case .failure:
            throw ProducerTestError.intentional
        case .cancellation:
            throw CancellationError()
        }
    }

    func savePlan(_ plan: FixPlan, decision: FixPlanReviewDecision) {
        saved.append((plan, decision))
    }

    func albumContextInputs() -> [[String]] {
        albumContextInputIDs
    }

    func determinationCalls() -> [DeterminationCall] {
        calls
    }

    func savedPlans() -> [(plan: FixPlan, decision: FixPlanReviewDecision)] {
        saved
    }
}

private struct DeterminationCall: Equatable {
    let trackID: String
    let albumTrackIDs: [String]
    let artistTrackIDs: [String]
    let updateGenre: Bool
    let updateYear: Bool
    let minConfidence: Int
}

private enum DeterminationOutcome {
    case changes([ProposedChange])
    case trackNotEditable
    case missingAppleScriptID
    case failure
    case cancellation
}

private enum ProducerTestError: Error, Equatable {
    case intentional
}

private func track(
    _ id: String,
    artist: String = "Artist",
    album: String = "Album"
) -> Track {
    Track(id: id, name: "Track \(id)", artist: artist, album: album)
}

private func proposal(
    for track: Track,
    confidence: Int = 80
) -> ProposedChange {
    ProposedChange(
        track: track,
        changeType: .genreUpdate,
        oldValue: "Rock",
        newValue: "Electronic",
        confidence: confidence,
        source: "unit-test"
    )
}
