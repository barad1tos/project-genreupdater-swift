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
    func storesReplacement() async {
        let store = ProjectionStore()
        let replacement = makeProjection(revision: ProjectionRevision(3), title: "Replacement")
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))

        let returnedProjection = await store.replaceActivityProjection(replacement)
        let currentProjection = await store.activityProjection()

        #expect(returnedProjection == expectedProjection)
        #expect(currentProjection == expectedProjection)
    }

    @Test("activity updates stream publishes initial and replacement")
    func publishesActivityUpdates() async throws {
        let store = ProjectionStore()
        let replacement = makeProjection(revision: ProjectionRevision(5), title: "Replacement")
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))
        let updates = await store.activityUpdates()
        let iterator = ActivityUpdateIterator(stream: updates)

        let initialProjection = try await nextProjection(from: iterator)
        #expect(initialProjection == .empty())

        await store.replaceActivityProjection(replacement)

        let updatedProjection = try await nextProjection(from: iterator)
        #expect(updatedProjection == expectedProjection)
    }

    @Test("replace assigns next revision independent of incoming revision")
    func assignsNextRevision() async {
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
    func preservesStableRevision() async {
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
    func rejectsOldActivityInput() async {
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
    func survivesRecreatedHosts() async {
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

    @Test("stores current fix plan projection")
    func storesFixPlanProjection() async {
        let store = ProjectionStore()
        let replacement = makeFixPlanProjection(
            message: "Fix plan store unavailable",
            revision: ProjectionRevision(99)
        )

        let initialProjection = await store.fixPlanProjection()
        let returnedProjection = await store.replaceFixPlanProjection(replacement)
        let currentProjection = await store.fixPlanProjection()

        #expect(initialProjection == .empty())
        #expect(returnedProjection.revision == ProjectionRevision(1))
        #expect(currentProjection == returnedProjection)
    }

    @Test("fix plan updates stream publishes initial and replacement")
    func publishesFixPlanUpdates() async throws {
        let store = ProjectionStore()
        let replacement = makeFixPlanProjection(message: "Updated fix plan", revision: ProjectionRevision(5))
        let expectedProjection = replacement.withRevision(ProjectionRevision(1))
        let updates = await store.fixPlanUpdates()
        let iterator = FixPlanUpdateIterator(stream: updates)

        let initialProjection = try await nextProjection(from: iterator)
        #expect(initialProjection == .empty())

        await store.replaceFixPlanProjection(replacement)

        let updatedProjection = try await nextProjection(from: iterator)
        #expect(updatedProjection == expectedProjection)
    }

    @Test("fix plan input generation rejects older replacements")
    func rejectsOldFixPlanInput() async {
        let store = ProjectionStore()
        let firstProjection = makeFixPlanProjection(message: "Current fix plan")
        let secondProjection = makeFixPlanProjection(message: "Stale replacement")

        let acceptedProjection = await store.replaceFixPlanProjection(firstProjection, inputGeneration: 2)
        let rejectedProjection = await store.replaceFixPlanProjection(secondProjection, inputGeneration: 1)
        let storedProjection = await store.fixPlanProjection()

        #expect(acceptedProjection.revision == ProjectionRevision(1))
        #expect(rejectedProjection == acceptedProjection)
        #expect(storedProjection == acceptedProjection)
    }

    @Test("reports activity and fix plan generations advance independently")
    func generationsStayIndependent() async {
        let store = ProjectionStore()

        let returnedActivityProjection = await store.replaceActivityProjection(makeProjection())
        let returnedReportsProjection = await store.replaceReportsProjection(
            ReportsProjection(revision: .initial, runs: [], skippedCorruptedCount: 1)
        )
        let returnedFixPlanProjection = await store.replaceFixPlanProjection(
            makeFixPlanProjection(message: "Independent fix plan")
        )

        #expect(returnedActivityProjection.revision == ProjectionRevision(1))
        #expect(returnedReportsProjection.revision == ProjectionRevision(1))
        #expect(returnedFixPlanProjection.revision == ProjectionRevision(1))
    }
}

private final class ActivityUpdateIterator: @unchecked Sendable {
    private var iterator: AsyncStream<ActivityProjection>.Iterator

    init(stream: AsyncStream<ActivityProjection>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> ActivityProjection? {
        await iterator.next()
    }
}

private final class FixPlanUpdateIterator: @unchecked Sendable {
    private var iterator: AsyncStream<FixPlanProjection>.Iterator

    init(stream: AsyncStream<FixPlanProjection>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> FixPlanProjection? {
        await iterator.next()
    }
}

private enum ProjectionStoreTestError: Error, CustomStringConvertible {
    case timedOut

    var description: String {
        "Timed out waiting for projection update"
    }
}

private func nextProjection(
    from iterator: ActivityUpdateIterator,
    timeout: Duration = .seconds(1)
) async throws -> ActivityProjection? {
    try await withThrowingTaskGroup(of: ActivityProjection?.self) { group in
        // ActivityUpdateIterator is captured here; tests call next() serially and the timeout task never touches it.
        group.addTask {
            await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProjectionStoreTestError.timedOut
        }

        let projectionResult = try await group.next()
        group.cancelAll()
        guard let projectionResult else { return nil }
        return projectionResult
    }
}

private func nextProjection(
    from iterator: FixPlanUpdateIterator,
    timeout: Duration = .seconds(1)
) async throws -> FixPlanProjection? {
    try await withThrowingTaskGroup(of: FixPlanProjection?.self) { group in
        // FixPlanUpdateIterator is captured here; tests call next() serially and the timeout task never touches it.
        group.addTask {
            await iterator.next()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProjectionStoreTestError.timedOut
        }

        let projectionResult = try await group.next()
        group.cancelAll()
        guard let projectionResult else { return nil }
        return projectionResult
    }
}

private func makeProjection(
    revision: ProjectionRevision = .initial,
    title: String = "Projection"
) -> ActivityProjection {
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

private func makeFixPlanProjection(
    message: String,
    revision: ProjectionRevision = .initial
) -> FixPlanProjection {
    FixPlanProjection.unavailable(message: message).withRevision(revision)
}
