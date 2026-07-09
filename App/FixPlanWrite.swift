import Core
import Foundation
import Services

enum FixPlanWrite {
    enum Failure: LocalizedError {
        case missingPlan(FixPlanID)
        case missingDecision(FixPlanID)
        case staleDecision
        case noAcceptedItems

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
            }
        }
    }

    static func proposedChanges(
        from plan: FixPlan,
        decision: FixPlanReviewDecision
    ) -> [ProposedChange] {
        let verdicts = Dictionary(uniqueKeysWithValues: decision.itemDecisions.map { ($0.itemID, $0.verdict) })
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
