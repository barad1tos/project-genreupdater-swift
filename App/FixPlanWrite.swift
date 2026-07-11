import Core
import Foundation
import Services

enum FixPlanWrite {
    struct ScriptAccess {
        let client: any AppleScriptClient
        let batchSize: @Sendable () async -> Int
    }

    struct RunnerDependencies {
        let updateCoordinator: UpdateCoordinator
        let fixPlanStore: any FixPlanStore
        let mapper: TrackIDMapper
        let script: ScriptAccess
        let batchProcessor: BatchProcessor
        let hasRunRecovery: @Sendable () async -> Bool
    }

    enum Failure: LocalizedError {
        case missingPlan(FixPlanID)
        case missingDecision(FixPlanID)
        case staleDecision
        case noAcceptedItems
        case invalidDecisionItems(FixPlanID)
        case missingWriteTracks(Int)

        var errorDescription: String? {
            switch self {
            case let .missingPlan(planID):
                "Fix plan \(planID.description) is unavailable"
            case let .missingDecision(planID):
                "Review decision is missing for fix plan \(planID.description)"
            case .staleDecision:
                "Review decision changed before write run started"
            case .noAcceptedItems:
                "Fix plan has no accepted items to write"
            case let .invalidDecisionItems(planID):
                "Review decision items do not match fix plan \(planID.description)"
            case let .missingWriteTracks(count):
                "Could not refresh \(count) reviewed write tracks from Music.app"
            }
        }
    }

    static func proposedChanges(
        from plan: FixPlan,
        decision: FixPlanReviewDecision
    ) throws -> [ProposedChange] {
        let verdicts = try itemVerdicts(from: decision, matching: plan)
        return plan.items.map { item in
            ProposedChange(
                id: item.id,
                track: track(from: item),
                changeType: item.changeType,
                oldValue: item.oldValue,
                newValue: item.newValue,
                confidence: item.confidence,
                source: item.source,
                isAccepted: verdicts[item.id] == .accepted
            )
        }
    }

    private static func itemVerdicts(
        from decision: FixPlanReviewDecision,
        matching plan: FixPlan
    ) throws -> [UUID: FixPlanItemVerdict] {
        let planItemIDs = Set(plan.items.map(\.id))
        var verdicts: [UUID: FixPlanItemVerdict] = [:]
        for itemDecision in decision.itemDecisions {
            guard planItemIDs.contains(itemDecision.itemID),
                  verdicts[itemDecision.itemID] == nil
            else {
                throw Failure.invalidDecisionItems(plan.id)
            }
            verdicts[itemDecision.itemID] = itemDecision.verdict
        }
        guard verdicts.count == planItemIDs.count else {
            throw Failure.invalidDecisionItems(plan.id)
        }
        return verdicts
    }

    static func prepareWriteIDs(
        for changes: [ProposedChange],
        mapper: TrackIDMapper,
        scriptClient: any AppleScriptClient,
        writeIDBatchSize: Int
    ) async throws {
        var targetsByReadID: [String: (track: Track, appleScriptID: String)] = [:]
        for change in changes {
            guard let appleScriptID = change.track.appleScriptID else { continue }
            targetsByReadID[change.track.id] = (change.track, appleScriptID)
        }
        guard !targetsByReadID.isEmpty else { return }

        let appleScriptIDs = Array(Set(targetsByReadID.values.map(\.appleScriptID)))
        let currentTracks = try await scriptClient.fetchTracksByIDs(
            appleScriptIDs,
            batchSize: writeIDBatchSize,
            timeout: nil
        )
        var currentTracksByID: [String: Track] = [:]
        for track in currentTracks {
            currentTracksByID[track.appleScriptID ?? track.id] = track
        }
        let entries = targetsByReadID.values.compactMap { target in
            currentTracksByID[target.appleScriptID].map { currentTrack in
                (musicKitTrack: target.track, appleScriptTrack: currentTrack)
            }
        }
        guard entries.count == targetsByReadID.count else {
            throw Failure.missingWriteTracks(targetsByReadID.count - entries.count)
        }

        await mapper.seedKnownMappings(entries)
    }

    static func makeRunner(
        _ dependencies: RunnerDependencies
    ) -> @Sendable (FixPlanWriteTarget) async throws -> BatchUpdateResult {
        { target in
            if await dependencies.hasRunRecovery() {
                throw WriteAdmissionError.recoveryRequired
            }
            return try await dependencies.batchProcessor.performRecoverableWrite {
                guard let plan = try await dependencies.fixPlanStore.plan(
                    id: target.planID,
                    revision: target.planRevision
                ) else {
                    throw Failure.missingPlan(target.planID)
                }
                guard let decision = try await dependencies.fixPlanStore.currentDecision(for: target.planID) else {
                    throw Failure.missingDecision(target.planID)
                }
                guard decision.planRevision == target.planRevision,
                      decision.revision == target.decisionRevision
                else {
                    throw Failure.staleDecision
                }

                let changes = try proposedChanges(from: plan, decision: decision)
                let acceptedChanges = changes.filter(\.isAccepted)
                guard !acceptedChanges.isEmpty else {
                    throw Failure.noAcceptedItems
                }

                try await prepareWriteIDs(
                    for: acceptedChanges,
                    mapper: dependencies.mapper,
                    scriptClient: dependencies.script.client,
                    writeIDBatchSize: dependencies.script.batchSize()
                )
                return try await dependencies.updateCoordinator.applyAcceptedChanges(
                    changes,
                    progressHandler: ignoreProgress
                )
            }
        }
    }

    private static func track(from item: FixPlanItem) -> Track {
        Track(
            id: item.identity.readID,
            name: item.identity.trackName,
            artist: item.identity.artist,
            album: item.identity.album,
            genre: item.changeType == .genreUpdate ? item.oldValue : nil,
            year: item.changeType == .yearUpdate ? year(from: item.oldValue) : nil,
            appleScriptID: item.identity.appleScriptID
        )
    }

    private static func year(from value: String?) -> Int? {
        value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func ignoreProgress(_: ProgressUpdate) {
        // Fix-plan writes do not expose intermediate progress.
    }
}

extension AppDependencies {
    func makeWriteRunner() -> (@Sendable (FixPlanWriteTarget) async throws -> BatchUpdateResult)? {
        guard let updateCoordinator,
              let fixPlanStore,
              let mapper = trackIDMapper,
              let writeScript,
              let batchProcessor
        else {
            AppLogger.make(category: "dependencies")
                .warning("Fix plan writer unavailable: missing write prerequisites")
            assertionFailure("Fix plan writer unavailable: missing write prerequisites")
            return nil
        }
        let hasRunRecovery: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return true }
            return await self.hasRecoveryHold()
        }

        return FixPlanWrite.makeRunner(FixPlanWrite.RunnerDependencies(
            updateCoordinator: updateCoordinator,
            fixPlanStore: fixPlanStore,
            mapper: mapper,
            script: writeScript,
            batchProcessor: batchProcessor,
            hasRunRecovery: hasRunRecovery
        ))
    }
}
