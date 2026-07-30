import Core
import Foundation

/// Re-reads uncertain work items from Music.app and classifies each against
/// its planned change (ADR 0006: observed state wins).
///
/// `.prepared` items were never dispatched, so they close as `.skipped`
/// without observation. `.attempting`/`.attempted` items are re-read by their
/// AppleScript write identity; absent tracks and missing identities classify
/// as `.needsReview`. Fetch failures propagate so recovery clearance stays
/// blocked while the physical state cannot be checked (fail closed).
actor RecoveryObservationService {
    private let scriptClient: any AppleScriptClient
    private let batchSize: Int

    init(scriptClient: any AppleScriptClient, batchSize: Int = 50) {
        self.scriptClient = scriptClient
        self.batchSize = batchSize
    }

    func observeOutcomes(for items: [RunWorkItem]) async throws -> [UUID: WorkOutcome] {
        var outcomes: [UUID: WorkOutcome] = [:]
        var observationIDs: [UUID: String] = [:]
        for item in items {
            switch item.state {
            case .outcome:
                continue
            case .prepared:
                outcomes[item.id] = .skipped
            case .attempting, .attempted:
                if case let .track(identity) = item.target,
                   let appleScriptID = identity.appleScriptID,
                   !appleScriptID.isEmpty {
                    observationIDs[item.id] = appleScriptID
                } else {
                    outcomes[item.id] = .needsReview
                }
            }
        }
        guard !observationIDs.isEmpty else {
            return outcomes
        }

        let uniqueIDs = Array(Set(observationIDs.values))
        let tracks = try await scriptClient.fetchTracksByIDs(
            uniqueIDs,
            batchSize: batchSize,
            timeout: nil
        )
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (itemID, scriptID) in observationIDs {
            guard let item = items.first(where: { $0.id == itemID }) else { continue }
            guard let track = tracksByID[scriptID] else {
                outcomes[itemID] = .needsReview
                continue
            }
            let property = AppleScriptTrackProperty(changeType: item.change.changeType)
            outcomes[itemID] = RecoveryObservation.outcome(
                for: item,
                observedValue: property.currentValue(in: track)
            )
        }
        return outcomes
    }
}
