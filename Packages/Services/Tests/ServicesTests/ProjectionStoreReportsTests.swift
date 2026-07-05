import Services
import Testing

@Suite("ProjectionStore reports")
struct ProjectionStoreReportsTests {
    @Test("stores current reports projection")
    func storesCurrentReportsProjection() async {
        let store = ProjectionStore()

        let projection = await store.reportsProjection()

        #expect(projection == .empty())
    }

    @Test("replace updates current and returns replacement")
    func replaceUpdatesCurrentAndReturnsReplacement() async {
        let store = ProjectionStore()
        let replacement = makeProjection(revision: ProjectionRevision(3), skippedCorruptedCount: 2)
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))

        let returnedProjection = await store.replaceReportsProjection(replacement)
        let currentProjection = await store.reportsProjection()

        #expect(returnedProjection == expectedProjection)
        #expect(currentProjection == expectedProjection)
    }

    @Test("reports updates stream publishes initial and replacement")
    func reportsUpdatesStreamPublishesInitialAndReplacement() async throws {
        let store = ProjectionStore()
        let replacement = makeProjection(revision: ProjectionRevision(5), skippedCorruptedCount: 3)
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))
        let updates = await store.reportsUpdates()
        let iterator = ReportsProjectionUpdateIterator(stream: updates)

        let initialProjection = try await nextProjection(from: iterator)
        #expect(initialProjection == .empty())

        await store.replaceReportsProjection(replacement)

        let updatedProjection = try await nextProjection(from: iterator)
        #expect(updatedProjection == expectedProjection)
    }

    @Test("replace assigns next revision independent of incoming revision")
    func replaceAssignsNextRevisionIndependentOfIncomingRevision() async {
        let store = ProjectionStore()
        let firstProjection = makeProjection(revision: ProjectionRevision(99), skippedCorruptedCount: 1)
        let secondProjection = makeProjection(revision: .initial, skippedCorruptedCount: 2)

        let firstReturnedProjection = await store.replaceReportsProjection(firstProjection)
        let secondReturnedProjection = await store.replaceReportsProjection(secondProjection)
        let storedProjection = await store.reportsProjection()

        #expect(firstReturnedProjection.revision == ProjectionRevision(1))
        #expect(secondReturnedProjection.revision == ProjectionRevision(2))
        #expect(secondReturnedProjection.skippedCorruptedCount == 2)
        #expect(storedProjection == secondReturnedProjection)
    }

    @Test("content identical replacement preserves revision")
    func contentIdenticalReplacementPreservesRevision() async {
        let store = ProjectionStore()
        let projection = makeProjection(revision: .initial, skippedCorruptedCount: 4)
        let refreshedProjection = makeProjection(revision: ProjectionRevision(99), skippedCorruptedCount: 4)

        let firstReturnedProjection = await store.replaceReportsProjection(projection)
        let secondReturnedProjection = await store.replaceReportsProjection(refreshedProjection)
        let storedProjection = await store.reportsProjection()

        #expect(firstReturnedProjection.revision == ProjectionRevision(1))
        #expect(secondReturnedProjection == firstReturnedProjection)
        #expect(storedProjection == firstReturnedProjection)
    }

    @Test("older input generation cannot replace newer projection")
    func olderInputGenerationCannotReplaceNewerProjection() async {
        let store = ProjectionStore()
        let newerProjection = makeProjection(revision: .initial, skippedCorruptedCount: 5)
        let olderProjection = makeProjection(revision: .initial, skippedCorruptedCount: 6)

        let acceptedProjection = await store.replaceReportsProjection(newerProjection, inputGeneration: 2)
        let rejectedProjection = await store.replaceReportsProjection(olderProjection, inputGeneration: 1)
        let storedProjection = await store.reportsProjection()

        #expect(acceptedProjection.revision == ProjectionRevision(1))
        #expect(rejectedProjection == acceptedProjection)
        #expect(storedProjection == acceptedProjection)
    }

    @Test("store-owned input generations survive recreated hosts")
    func storeOwnedInputGenerationsSurviveRecreatedHosts() async {
        let store = ProjectionStore()
        let firstProjection = makeProjection(revision: .initial, skippedCorruptedCount: 7)
        let secondProjection = makeProjection(revision: .initial, skippedCorruptedCount: 8)

        let firstGeneration = await store.nextReportsProjectionInputGeneration()
        let acceptedFirstProjection = await store.replaceReportsProjection(
            firstProjection,
            inputGeneration: firstGeneration
        )
        let secondGeneration = await store.nextReportsProjectionInputGeneration()
        let acceptedSecondProjection = await store.replaceReportsProjection(
            secondProjection,
            inputGeneration: secondGeneration
        )
        let storedProjection = await store.reportsProjection()

        #expect(secondGeneration > firstGeneration)
        #expect(acceptedFirstProjection.revision == ProjectionRevision(1))
        #expect(acceptedSecondProjection.revision == ProjectionRevision(2))
        #expect(acceptedSecondProjection.skippedCorruptedCount == 8)
        #expect(storedProjection == acceptedSecondProjection)
    }

    @Test("reports and activity generations advance independently")
    func reportsAndActivityGenerationsAdvanceIndependently() async {
        let store = ProjectionStore()

        let returnedActivityProjection = await store.replaceActivityProjection(makeActivityProjection())
        let returnedReportsProjection = await store.replaceReportsProjection(
            makeProjection(revision: .initial, skippedCorruptedCount: 9)
        )

        #expect(returnedActivityProjection.revision == ProjectionRevision(1))
        #expect(returnedReportsProjection.revision == ProjectionRevision(1))
    }

    private func makeProjection(revision: ProjectionRevision, skippedCorruptedCount: Int) -> ReportsProjection {
        ReportsProjection(revision: revision, runs: [], skippedCorruptedCount: skippedCorruptedCount)
    }

    private func makeActivityProjection() -> ActivityProjection {
        ActivityProjection(
            revision: .initial,
            title: "Independent activity",
            subtitle: "Subtitle",
            syncStatusText: "Status",
            currentStage: .watch,
            processingMode: .preview,
            automationState: .noSyncYet,
            deltaCount: 0,
            interventionCount: 0,
            protectedCount: 0,
            failedWriteCount: 0,
            isUndoReady: false,
            primaryCommand: nil,
            secondaryCommand: nil,
            stageDescriptors: [],
            recentActivity: [],
            summaryCards: [],
            operationalIssues: []
        )
    }
}

private final class ReportsProjectionUpdateIterator: @unchecked Sendable {
    private var iterator: AsyncStream<ReportsProjection>.Iterator

    init(stream: AsyncStream<ReportsProjection>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ReportsProjection? {
        await iterator.next()
    }
}

private enum ProjectionStoreReportsTestError: Error, CustomStringConvertible {
    case timedOutWaitingForProjection

    var description: String {
        "Timed out waiting for reports projection update"
    }
}

private func nextProjection(
    from iterator: ReportsProjectionUpdateIterator,
    timeout: Duration = .seconds(1)
) async throws -> ReportsProjection? {
    try await withThrowingTaskGroup(of: ReportsProjection?.self) { group in
        // ReportsProjectionUpdateIterator is captured here; tests call next() serially and the timeout task never
        // touches it.
        group.addTask {
            await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProjectionStoreReportsTestError.timedOutWaitingForProjection
        }

        let projectionResult = try await group.next()
        group.cancelAll()
        guard let projectionResult else { return nil }
        return projectionResult
    }
}
