import Services
import Testing

@Suite("ProjectionStore")
struct ProjectionStoreTests {
    @Test("stores current activity projection")
    func storesCurrentActivityProjection() async {
        let store = ProjectionStore()

        let projection = await store.activityProjection()

        #expect(projection == .empty())
    }

    @Test("replace updates current and returns replacement")
    func replaceUpdatesCurrentAndReturnsReplacement() async {
        let store = ProjectionStore()
        let replacement = makeProjection(revision: ProjectionRevision(3), title: "Replacement")
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))

        let returnedProjection = await store.replaceActivityProjection(replacement)
        let currentProjection = await store.activityProjection()

        #expect(returnedProjection == expectedProjection)
        #expect(currentProjection == expectedProjection)
    }

    @Test("activity updates stream publishes initial and replacement")
    func activityUpdatesStreamPublishesInitialAndReplacement() async throws {
        let store = ProjectionStore()
        let replacement = makeProjection(revision: ProjectionRevision(5), title: "Replacement")
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))
        let updates = await store.activityUpdates()
        let iterator = ProjectionUpdateIterator(stream: updates)

        let initialProjection = try await nextProjection(from: iterator)
        #expect(initialProjection == .empty())

        await store.replaceActivityProjection(replacement)

        let updatedProjection = try await nextProjection(from: iterator)
        #expect(updatedProjection == expectedProjection)
    }

    @Test("replace assigns next revision independent of incoming revision")
    func replaceAssignsNextRevisionIndependentOfIncomingRevision() async {
        let store = ProjectionStore()
        let firstProjection = makeProjection(revision: ProjectionRevision(99), title: "First")
        let secondProjection = makeProjection(revision: .initial, title: "Second")

        let firstReturnedProjection = await store.replaceActivityProjection(firstProjection)
        let secondReturnedProjection = await store.replaceActivityProjection(secondProjection)
        let storedProjection = await store.activityProjection()

        #expect(firstReturnedProjection.revision == ProjectionRevision(1))
        #expect(secondReturnedProjection.revision == ProjectionRevision(2))
        #expect(secondReturnedProjection.title == "Second")
        #expect(storedProjection == secondReturnedProjection)
    }

    @Test("each replacement advances revision")
    func eachReplacementAdvancesRevision() async {
        let store = ProjectionStore()
        let firstProjection = makeProjection(revision: .initial, title: "First")
        let refreshedProjection = makeProjection(revision: .initial, title: "Refreshed")

        let firstReturnedProjection = await store.replaceActivityProjection(firstProjection)
        let returnedProjection = await store.replaceActivityProjection(refreshedProjection)
        let storedProjection = await store.activityProjection()

        #expect(firstReturnedProjection.revision == ProjectionRevision(1))
        #expect(returnedProjection.revision == ProjectionRevision(2))
        #expect(returnedProjection.title == "Refreshed")
        #expect(storedProjection == returnedProjection)
    }

    @Test("content identical replacement preserves revision")
    func contentIdenticalReplacementPreservesRevision() async {
        let store = ProjectionStore()
        let projection = makeProjection(revision: .initial, title: "Stable")
        let refreshedProjection = makeProjection(revision: ProjectionRevision(99), title: "Stable")

        let firstReturnedProjection = await store.replaceActivityProjection(projection)
        let secondReturnedProjection = await store.replaceActivityProjection(refreshedProjection)
        let storedProjection = await store.activityProjection()

        #expect(firstReturnedProjection.revision == ProjectionRevision(1))
        #expect(secondReturnedProjection == firstReturnedProjection)
        #expect(storedProjection == firstReturnedProjection)
    }

    @Test("older input generation cannot replace newer projection")
    func olderInputGenerationCannotReplaceNewerProjection() async {
        let store = ProjectionStore()
        let newerProjection = makeProjection(revision: .initial, title: "Newer")
        let olderProjection = makeProjection(revision: .initial, title: "Older")

        let acceptedProjection = await store.replaceActivityProjection(newerProjection, inputGeneration: 2)
        let rejectedProjection = await store.replaceActivityProjection(olderProjection, inputGeneration: 1)
        let storedProjection = await store.activityProjection()

        #expect(acceptedProjection.revision == ProjectionRevision(1))
        #expect(rejectedProjection == acceptedProjection)
        #expect(storedProjection == acceptedProjection)
    }

    @Test("store-owned input generations survive recreated hosts")
    func storeOwnedInputGenerationsSurviveRecreatedHosts() async {
        let store = ProjectionStore()
        let firstProjection = makeProjection(revision: .initial, title: "First host")
        let secondProjection = makeProjection(revision: .initial, title: "Recreated host")

        let firstGeneration = await store.nextActivityProjectionInputGeneration()
        let acceptedFirstProjection = await store.replaceActivityProjection(
            firstProjection,
            inputGeneration: firstGeneration
        )
        let secondGeneration = await store.nextActivityProjectionInputGeneration()
        let acceptedSecondProjection = await store.replaceActivityProjection(
            secondProjection,
            inputGeneration: secondGeneration
        )
        let storedProjection = await store.activityProjection()

        #expect(secondGeneration > firstGeneration)
        #expect(acceptedFirstProjection.revision == ProjectionRevision(1))
        #expect(acceptedSecondProjection.revision == ProjectionRevision(2))
        #expect(acceptedSecondProjection.title == "Recreated host")
        #expect(storedProjection == acceptedSecondProjection)
    }
}

private final class ProjectionUpdateIterator: @unchecked Sendable {
    private var iterator: AsyncStream<ActivityProjection>.Iterator

    init(stream: AsyncStream<ActivityProjection>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ActivityProjection? {
        await iterator.next()
    }
}

private enum ProjectionStoreTestError: Error, CustomStringConvertible {
    case timedOutWaitingForProjection

    var description: String {
        "Timed out waiting for activity projection update"
    }
}

private func nextProjection(
    from iterator: ProjectionUpdateIterator,
    timeout: Duration = .seconds(1)
) async throws -> ActivityProjection? {
    try await withThrowingTaskGroup(of: ActivityProjection?.self) { group in
        // ProjectionUpdateIterator is captured here; tests call next() serially and the timeout task never touches it.
        group.addTask {
            await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProjectionStoreTestError.timedOutWaitingForProjection
        }

        let projectionResult = try await group.next()
        group.cancelAll()
        guard let projectionResult else { return nil }
        return projectionResult
    }
}

private func makeProjection(revision: ProjectionRevision, title: String) -> ActivityProjection {
    ActivityProjection(
        revision: revision,
        title: title,
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
