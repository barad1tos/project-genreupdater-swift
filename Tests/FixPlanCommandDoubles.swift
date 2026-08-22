import Core
import Foundation
import Services
@testable import Genre_Updater

@MainActor
final class FixPlanCommandHarness {
    let plan: FixPlan
    let store: MemoryFixPlanStore
    private var fixPlanProjection: FixPlanProjection
    private var activityProjection = ActivityProjection.empty(revision: ProjectionRevision(10))
    private var shouldRefreshProjection = true
    private var writeResult: RunSubmissionResult?
    private var writeError: (any Error)?
    private var writeInputs: [FixPlanWriteInput] = []
    var isRecoveryHeld = false
    var sourceRecord: RunRecord?
    var submittedRequests: [RunRequest] = []

    init(
        startingVerdict: FixPlanItemVerdict,
        plan: FixPlan = makeCommandPlan()
    ) {
        self.plan = plan
        let initial = FixPlanReviewer.initialDecision(for: plan, at: Date(timeIntervalSince1970: 1_800_000_101))
        let decision = startingVerdict == .accepted
            ? initial
            : FixPlanReviewer.rejectingAll(initial, at: Date(timeIntervalSince1970: 1_800_000_102))
        store = MemoryFixPlanStore(plan: plan, decision: decision)
        fixPlanProjection = Self.makeProjection(plan: plan, decision: decision).withRevision(ProjectionRevision(4))
    }

    var target: FixPlanCommandTarget {
        FixPlanCommandTarget(
            planID: plan.id,
            planRevision: plan.revision,
            decisionRevision: fixPlanProjection.decisionRevision ?? .initial,
            projectionRevision: fixPlanProjection.revision
        )
    }

    func makeCommands() -> FixPlanCommands {
        makeCommands(fixPlanStore: store)
    }

    func makeCommands(fixPlanStore: (any FixPlanStore)?) -> FixPlanCommands {
        FixPlanCommands(
            fixPlanStore: fixPlanStore,
            submitFixPlanWrite: { [self] input in
                try await submitWrite(input: input)
            },
            loadRunRecord: { [self] _ in
                sourceRecord
            },
            submitRunRequest: { [self] request in
                submittedRequests.append(request)
                if let writeError {
                    throw writeError
                }
                return writeResult ?? .recoveryRequired
            },
            ensureRecoveryHold: { [self] in
                isRecoveryHeld
            },
            refreshFixPlanProjection: { [self] in
                await refreshFixPlanProjection()
            },
            refreshActivityProjection: { [self] in
                refreshActivityProjection()
            },
            now: { Date(timeIntervalSince1970: 1_800_000_200) }
        )
    }

    func setWriteResult(_ result: RunSubmissionResult) {
        writeResult = result
    }

    func setRecoveryResult(reason: String) {
        writeResult = .recoverable(Self.recoveryLifecycle(), reason: reason)
    }

    func markProjectionStale() {
        fixPlanProjection = FixPlanProjection(
            revision: fixPlanProjection.revision,
            status: .stale,
            lineage: fixPlanProjection.lineage,
            scope: fixPlanProjection.scope,
            summary: FixPlanProjection.Summary(
                itemCount: fixPlanProjection.itemCount,
                acceptedCount: fixPlanProjection.acceptedCount,
                rejectedCount: fixPlanProjection.rejectedCount,
                genreCount: fixPlanProjection.genreCount,
                yearCount: fixPlanProjection.yearCount,
                trackCleaningCount: fixPlanProjection.trackCleaningCount,
                albumCleaningCount: fixPlanProjection.albumCleaningCount,
                artistRenameCount: fixPlanProjection.artistRenameCount,
                affectedTrackCount: fixPlanProjection.affectedTrackCount,
                affectedAlbumCount: fixPlanProjection.affectedAlbumCount,
                averageConfidence: fixPlanProjection.averageConfidence,
                canApply: false
            ),
            stalenessReasons: [.scopeChanged],
            items: fixPlanProjection.items,
            operationalIssues: fixPlanProjection.operationalIssues
        )
        shouldRefreshProjection = false
    }

    func failNextWrite(_ error: any Error) {
        writeError = error
    }

    func writeCallCount() -> Int {
        writeInputs.count
    }

    func lastWriteInput() -> FixPlanWriteInput? {
        writeInputs.last
    }

    private func submitWrite(input: FixPlanWriteInput) async throws -> RunSubmissionResult {
        writeInputs.append(input)
        if let writeError {
            self.writeError = nil
            throw writeError
        }
        return writeResult ?? .completed(Self.writeLifecycle(changeCount: input.workItems.count))
    }

    private func refreshFixPlanProjection() async -> FixPlanProjection {
        guard shouldRefreshProjection else {
            return fixPlanProjection
        }
        guard let decision = try? await store.currentDecision(for: plan.id) else {
            return fixPlanProjection
        }
        let candidate = Self.makeProjection(plan: plan, decision: decision)
        if candidate.withRevision(fixPlanProjection.revision) == fixPlanProjection {
            return fixPlanProjection
        }
        fixPlanProjection = candidate.withRevision(fixPlanProjection.revision.advanced())
        return fixPlanProjection
    }

    private func refreshActivityProjection() -> ActivityProjection {
        activityProjection = activityProjection.withRevision(activityProjection.revision.advanced())
        return activityProjection
    }

    private static func makeProjection(
        plan: FixPlan,
        decision: FixPlanReviewDecision
    ) -> FixPlanProjection {
        FixPlanProjector.makeProjection(
            plan: plan,
            decision: decision,
            staleness: FixPlanStaleness.evaluate(
                plan: plan,
                currentScope: plan.scope,
                currentConfiguration: plan.configuration
            )
        )
    }

    private static func writeLifecycle(changeCount: Int) -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(rawValue: commandUUID("00000000-0000-0000-0000-000000000301")),
            requestID: RunRequestID(rawValue: commandUUID("00000000-0000-0000-0000-000000000302")),
            trigger: .manualCheck,
            intent: .writeFixes,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Björk"],
                knownTrackCount: 12,
                createdAt: Date(timeIntervalSince1970: 1_800_000_250),
                reason: "fixPlanWrite"
            ),
            startedAt: Date(timeIntervalSince1970: 1_800_000_250),
            phase: .finished(.completed(writeSyncResult(changeCount: changeCount)), finishedAt: Date(
                timeIntervalSince1970: 1_800_000_260
            ))
        )
    }

    static func finishedLifecycle() -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(rawValue: commandUUID("00000000-0000-0000-0000-000000000305")),
            requestID: RunRequestID(rawValue: commandUUID("00000000-0000-0000-0000-000000000306")),
            trigger: .recovery,
            intent: .writeFixes,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Björk"],
                knownTrackCount: 12,
                createdAt: Date(timeIntervalSince1970: 1_800_000_260),
                reason: "fixPlanContinuation"
            ),
            startedAt: Date(timeIntervalSince1970: 1_800_000_260),
            phase: .finished(.completedNoOp(SyncResult()), finishedAt: Date(timeIntervalSince1970: 1_800_000_261))
        )
    }

    private static func recoveryLifecycle() -> RunLifecycleSnapshot {
        RunLifecycleSnapshot(
            runID: RunID(rawValue: commandUUID("00000000-0000-0000-0000-000000000303")),
            requestID: RunRequestID(rawValue: commandUUID("00000000-0000-0000-0000-000000000304")),
            trigger: .manualCheck,
            intent: .writeFixes,
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: ["Björk"],
                knownTrackCount: 12,
                createdAt: Date(timeIntervalSince1970: 1_800_000_250),
                reason: "fixPlanWrite"
            ),
            startedAt: Date(timeIntervalSince1970: 1_800_000_250),
            phase: .suspended(.recoverable)
        )
    }

    private static func writeSyncResult(changeCount: Int) -> SyncResult {
        SyncResult(modifiedTracks: (0 ..< changeCount).map { index in
            Track(id: "written-\(index)", name: "Jóga", artist: "Björk", album: "Homogenic")
        })
    }
}

actor MemoryFixPlanStore: FixPlanStore {
    private enum RecordBehavior {
        case save
        case conflict
        case missingPlan
        case throwError
    }

    private let plan: FixPlan
    private var decision: FixPlanReviewDecision?
    private var recordBehavior = RecordBehavior.save
    private var recordCalls = 0

    init(plan: FixPlan, decision: FixPlanReviewDecision) {
        self.plan = plan
        self.decision = decision
    }

    func savePlan(_: FixPlan, initialDecision _: FixPlanReviewDecision) async throws {
        // Mock: command tests seed the plan via init, saving is a no-op.
    }

    func plan(id: FixPlanID, revision: FixPlanRevision) async throws -> FixPlan? {
        guard plan.id == id, plan.revision == revision else { return nil }
        return plan
    }

    func latestPlan() async throws -> FixPlan? {
        plan
    }

    func currentDecision(for planID: FixPlanID) async throws -> FixPlanReviewDecision? {
        guard plan.id == planID else { return nil }
        return decision
    }

    func recordDecision(_ decision: FixPlanReviewDecision) async throws -> FixPlanDecisionWriteResult {
        recordCalls += 1
        switch recordBehavior {
        case .save:
            break
        case .conflict:
            recordBehavior = .save
            return .conflict(current: currentDecision())
        case .missingPlan:
            recordBehavior = .save
            throw FixPlanPersistenceError.missingPlan(planID: plan.id.rawValue)
        case .throwError:
            recordBehavior = .save
            throw StoreWriteError()
        }

        let current = currentDecision()
        guard decision.planID == plan.id,
              decision.planRevision == current.planRevision,
              decision.revision == current.revision.advanced()
        else {
            return .conflict(current: current)
        }
        self.decision = decision
        return .saved(decision)
    }

    func deletePlans(notIn _: Set<FixPlanID>) async throws -> Int {
        0
    }

    func currentDecision() -> FixPlanReviewDecision {
        guard let decision else {
            preconditionFailure("missing decision")
        }
        return decision
    }

    func replaceDecision(_ decision: FixPlanReviewDecision) {
        self.decision = decision
    }

    func removeDecision() {
        decision = nil
    }

    func conflictOnNextRecord() {
        recordBehavior = .conflict
    }

    func missingPlanOnNextRecord() {
        recordBehavior = .missingPlan
    }

    func throwOnNextRecord() {
        recordBehavior = .throwError
    }

    func recordCallCount() -> Int {
        recordCalls
    }

    func verdicts() -> [FixPlanItemVerdict] {
        currentDecision().itemDecisions.map(\.verdict)
    }
}

struct StoreWriteError: LocalizedError {
    var errorDescription: String? {
        "Test store write failed"
    }
}

func makeCommandPlan(firstHasWriteID: Bool = true) -> FixPlan {
    FixPlan(
        id: FixPlanID(rawValue: commandUUID("00000000-0000-0000-0000-000000000101")),
        revision: .initial,
        sourceRunID: RunID(rawValue: commandUUID("00000000-0000-0000-0000-000000000102")),
        createdAt: Date(timeIntervalSince1970: 1_800_000_100),
        configuration: FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(
                updateGenre: true,
                updateYear: true,
                repairExistingGenreMismatches: false,
                forceYearLookup: false,
                cleanTrackNames: false,
                cleanAlbumNames: false,
                minConfidence: 80,
                autoAccept: false
            ),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_090)
        ),
        scope: ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Björk"],
            knownTrackCount: 12,
            createdAt: Date(timeIntervalSince1970: 1_800_000_091),
            reason: "fixPlanCommandTest"
        ),
        items: [
            makeCommandItem(
                id: "00000000-0000-0000-0000-000000000201",
                type: .genreUpdate,
                hasWriteID: firstHasWriteID
            ),
            makeCommandItem(id: "00000000-0000-0000-0000-000000000202", type: .yearUpdate)
        ]
    )
}

func makeCommandItem(
    id: String,
    type: ChangeType,
    hasWriteID: Bool = true
) -> FixPlanItem {
    let itemID = commandUUID(id)
    return FixPlanItem(
        id: itemID,
        identity: FixPlanItemIdentity(
            readID: "read-\(id)",
            appleScriptID: hasWriteID ? "script-\(id)" : nil,
            artist: "Björk",
            album: "Homogenic",
            trackName: type == .genreUpdate ? "Jóga" : "Bachelorette"
        ),
        changeType: type,
        oldValue: type == .genreUpdate ? "Alternative" : "1998",
        newValue: type == .genreUpdate ? "Art Pop" : "1997",
        confidence: 92,
        source: "MusicBrainz"
    )
}

func commandUUID(_ rawValue: String) -> UUID {
    guard let uuid = UUID(uuidString: rawValue) else {
        preconditionFailure("Invalid fix-plan command fixture UUID: \(rawValue)")
    }
    return uuid
}
