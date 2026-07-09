import Core
import Foundation
import Services

enum FixPlanWrite {
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
        let verdicts = try verdictsByItemID(from: decision, matching: plan)
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

    private static func verdictsByItemID(
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
}

extension AppDependencies {
    func makeWriteRunner() -> (@Sendable (FixPlanWriteTarget) async throws -> BatchUpdateResult)? {
        guard let updateCoordinator,
              let fixPlanStore,
              let mapper = trackIDMapper,
              let bridge = applescriptBridge
        else {
            AppLogger.make(category: "dependencies")
                .warning("Fix plan writer unavailable: missing write prerequisites")
            assertionFailure("Fix plan writer unavailable: missing write prerequisites")
            return nil
        }

        return { [updateCoordinator, fixPlanStore, mapper, bridge] target in
            guard let plan = try await fixPlanStore.plan(id: target.planID, revision: target.planRevision) else {
                throw FixPlanWrite.Failure.missingPlan(target.planID)
            }
            guard let decision = try await fixPlanStore.currentDecision(for: target.planID) else {
                throw FixPlanWrite.Failure.missingDecision(target.planID)
            }
            guard decision.planRevision == target.planRevision,
                  decision.revision == target.decisionRevision
            else {
                throw FixPlanWrite.Failure.staleDecision
            }

            let changes = try FixPlanWrite.proposedChanges(from: plan, decision: decision)
            let acceptedChanges = changes.filter(\.isAccepted)
            guard !acceptedChanges.isEmpty else {
                throw FixPlanWrite.Failure.noAcceptedItems
            }

            let writeIDBatchSize = await bridge.trackIDBatchSize
            try await FixPlanWrite.prepareWriteIDs(
                for: acceptedChanges,
                mapper: mapper,
                scriptClient: bridge,
                writeIDBatchSize: writeIDBatchSize
            )
            return try await updateCoordinator.applyAcceptedChanges(changes) { _ in }
        }
    }
}
