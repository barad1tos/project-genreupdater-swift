import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("FixPlanWrite")
struct FixPlanWriteTests {
    @Test("reviewed write ID refresh uses configured batch size")
    func usesWriteIDBatchSize() async throws {
        let scriptClient = WriteIDScriptSpy()
        let mapper = TrackIDMapper()
        let changes = (1 ... 3).map { index in
            ProposedChange(
                track: musicKitTrack(index: index),
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Metal",
                confidence: 90,
                source: "review-test"
            )
        }
        await scriptClient.setTracks(changes.map { appleScriptTrack(from: $0.track) })

        try await FixPlanWrite.prepareWriteIDs(
            for: changes,
            mapper: mapper,
            scriptClient: scriptClient,
            writeIDBatchSize: 2
        )

        let calls = await scriptClient.fetchCalls
        #expect(calls.map(\.batchSize) == [2])
        #expect(Set(calls.flatMap(\.trackIDs)) == ["AS-1", "AS-2", "AS-3"])
        for index in 1 ... 3 {
            #expect(await mapper.appleScriptID(forMusicKitID: "MK-\(index)") == "AS-\(index)")
        }
    }

    @Test("reviewed write maps decision verdicts")
    func mapsDecisionVerdicts() throws {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
                FixPlanItemDecision(itemID: secondItem.id, verdict: .rejected),
            ]
        )

        let changes = try FixPlanWrite.proposedChanges(from: plan, decision: decision)

        #expect(changes.map(\.id) == [firstItem.id, secondItem.id])
        #expect(changes.map(\.isAccepted) == [true, false])
    }

    @Test("reviewed write rejects duplicate decision items")
    func rejectsDuplicateItems() {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
                FixPlanItemDecision(itemID: firstItem.id, verdict: .rejected),
            ]
        )

        expectInvalidDecision(plan: plan, decision: decision)
    }

    @Test("reviewed write rejects unknown decision items")
    func rejectsUnknownItems() {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
                FixPlanItemDecision(itemID: UUID(), verdict: .rejected),
            ]
        )

        expectInvalidDecision(plan: plan, decision: decision)
    }

    @Test("reviewed write rejects missing decision items")
    func rejectsMissingItems() {
        let firstItem = fixPlanItem(id: UUID(), index: 1)
        let secondItem = fixPlanItem(id: UUID(), index: 2)
        let plan = fixPlan(items: [firstItem, secondItem])
        let decision = reviewDecision(
            for: plan,
            items: [
                FixPlanItemDecision(itemID: firstItem.id, verdict: .accepted),
            ]
        )

        expectInvalidDecision(plan: plan, decision: decision)
    }
}

private actor WriteIDScriptSpy: AppleScriptClient {
    private var tracksByID: [String: Track] = [:]
    private(set) var fetchCalls: [(trackIDs: [String], batchSize: Int)] = []

    func setTracks(_ tracks: [Track]) {
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    }

    func initialize() async throws {
        // This in-memory client requires no setup.
    }

    func runScript(
        name _: String,
        arguments _: [String],
        timeout _: Duration?
    ) async throws -> String? {
        nil
    }

    func fetchTracksByIDs(
        _ trackIDs: [String],
        batchSize: Int,
        timeout _: Duration?
    ) async throws -> [Track] {
        fetchCalls.append((trackIDs, batchSize))
        return trackIDs.compactMap { tracksByID[$0] }
    }

    func fetchAllTrackIDs(timeout _: Duration?) async throws -> [String] {
        Array(tracksByID.keys)
    }

    func fetchTracks(artist _: String?, timeout _: Duration?) async throws -> [Track] {
        Array(tracksByID.values)
    }

    func updateTrackProperty(
        trackID _: String,
        property _: String,
        value _: String
    ) async throws -> AppleScriptWriteResult {
        .noChange
    }

    func batchUpdateTracks(_: [(trackID: String, property: String, value: String)]) async throws {
        // This spy only exercises single-track writes.
    }
}

private func musicKitTrack(index: Int) -> Track {
    Track(
        id: "MK-\(index)",
        name: "Track \(index)",
        artist: "Artist",
        album: "Album",
        appleScriptID: "AS-\(index)"
    )
}

private func appleScriptTrack(from track: Track) -> Track {
    Track(
        id: track.appleScriptID ?? track.id,
        name: track.name,
        artist: track.artist,
        album: track.album,
        appleScriptID: track.appleScriptID
    )
}

private func fixPlan(items: [FixPlanItem]) -> FixPlan {
    let capturedAt = Date(timeIntervalSince1970: 100)
    return FixPlan(
        id: FixPlanID(),
        revision: .initial,
        sourceRunID: RunID(),
        createdAt: capturedAt,
        configuration: FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: capturedAt
        ),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: items.count,
            createdAt: capturedAt,
            reason: "unit-test"
        ),
        items: items
    )
}

private func reviewDecision(
    for plan: FixPlan,
    items: [FixPlanItemDecision]
) -> FixPlanReviewDecision {
    FixPlanReviewDecision(
        planID: plan.id,
        planRevision: plan.revision,
        revision: .initial,
        decidedAt: Date(timeIntervalSince1970: 110),
        itemDecisions: items
    )
}

private func expectInvalidDecision(
    plan: FixPlan,
    decision: FixPlanReviewDecision
) {
    do {
        _ = try FixPlanWrite.proposedChanges(from: plan, decision: decision)
        Issue.record("Expected invalid decision items")
    } catch let error as FixPlanWrite.Failure {
        guard case .invalidDecisionItems = error else {
            Issue.record("Expected invalidDecisionItems, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected FixPlanWrite.Failure, got \(error)")
    }
}

private func fixPlanItem(id: UUID, index: Int) -> FixPlanItem {
    FixPlanItem(
        id: id,
        identity: FixPlanItemIdentity(
            readID: "MK-\(index)",
            appleScriptID: "AS-\(index)",
            artist: "Artist",
            album: "Album",
            trackName: "Track \(index)"
        ),
        changeType: .genreUpdate,
        oldValue: "Rock",
        newValue: "Metal",
        confidence: 90,
        source: "review-test"
    )
}
