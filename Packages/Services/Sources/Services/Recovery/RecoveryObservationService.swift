import Core
import Foundation

/// Re-reads uncertain work items from Music.app and classifies each against
/// its persisted write effect (ADR 0006: observed state wins).
///
/// `.prepared` items were never dispatched, so they close as `.skipped`
/// without observation. `.attempting`/`.attempted` items are re-read by their
/// AppleScript write identity; absent tracks — including a whole deleted
/// selection — classify as `.needsReview` with a durable missing-track note,
/// so clearance stays possible while the evidence survives in the audit
/// trail. Fetch failures propagate so recovery clearance stays blocked while
/// the physical state cannot be checked (fail closed).
public struct RecoveryObservationService: Sendable {
    private let scriptClient: any AppleScriptClient
    private let batchSize: Int

    /// - Parameter batchSize: forwarded to the bridge's batched lookup; the
    ///   bridge clamps oversized values, so the default only bounds one call.
    public init(scriptClient: any AppleScriptClient, batchSize: Int = 50) {
        self.scriptClient = scriptClient
        self.batchSize = batchSize
    }

    public func observeOutcomes(for items: [RunWorkItem]) async throws -> [UUID: ObservedWorkOutcome] {
        var outcomes: [UUID: ObservedWorkOutcome] = [:]
        var observationIDs: [UUID: String] = [:]
        for item in items {
            switch item.state {
            case .outcome:
                continue
            case .prepared:
                outcomes[item.id] = ObservedWorkOutcome(outcome: .skipped, observedValue: nil)
            case .attempting, .attempted:
                if case let .track(identity) = item.target,
                   let appleScriptID = identity.appleScriptID,
                   !appleScriptID.isEmpty {
                    observationIDs[item.id] = appleScriptID
                } else {
                    outcomes[item.id] = ObservedWorkOutcome(outcome: .needsReview, observedValue: nil)
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
        let tracksByID = Dictionary(
            tracks.map { ($0.appleScriptID ?? $0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (itemID, scriptID) in observationIDs {
            guard let item = itemsByID[itemID] else { continue }
            guard let track = tracksByID[scriptID] else {
                outcomes[itemID] = ObservedWorkOutcome(outcome: .needsReview, observedValue: nil)
                continue
            }
            outcomes[itemID] = RecoveryObservation.outcome(for: item, observedTrack: track)
        }
        return outcomes
    }
}
