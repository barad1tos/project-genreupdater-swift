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
    private let verifier: any MusicAppVerifying

    public init(verifier: any MusicAppVerifying) {
        self.verifier = verifier
    }

    public func observeOutcomes(for items: [RunWorkItem]) async throws -> [UUID: ObservedWorkOutcome] {
        var outcomes: [UUID: ObservedWorkOutcome] = [:]
        var observationIDs: [UUID: MusicDatabaseTrackID] = [:]
        for item in items {
            switch item.state {
            case .outcome:
                continue
            case .prepared:
                outcomes[item.id] = ObservedWorkOutcome(outcome: .skipped, observedValue: nil)
            case .attempting, .attempted:
                if case let .track(identity) = item.target,
                   let databaseID = identity.appleScriptID.flatMap(MusicDatabaseTrackID.init(rawValue:)) {
                    observationIDs[item.id] = databaseID
                } else {
                    outcomes[item.id] = ObservedWorkOutcome(outcome: .needsReview, observedValue: nil)
                }
            }
        }
        guard !observationIDs.isEmpty else {
            return outcomes
        }

        let uniqueIDs = Array(Set(observationIDs.values))
        let tracks = try await verifier.fetchMetadata(for: uniqueIDs)
        let tracksByID = Dictionary(
            tracks.compactMap { track in track.databaseID.map { ($0, track) } },
            uniquingKeysWith: { first, _ in first }
        )
        let itemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (itemID, databaseID) in observationIDs {
            guard let item = itemsByID[itemID] else { continue }
            guard let track = tracksByID[databaseID] else {
                outcomes[itemID] = ObservedWorkOutcome(outcome: .needsReview, observedValue: nil)
                continue
            }
            guard case let .track(identity) = item.target,
                  identity.matchesCurrentTrack(track, allowing: item.effectiveChange)
            else {
                outcomes[itemID] = .identityMismatch
                continue
            }
            outcomes[itemID] = RecoveryObservation.outcome(for: item, observedTrack: track)
        }
        return outcomes
    }
}
