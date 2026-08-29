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
/// trail. Evidence-less terminal no-ops from legacy payloads are also re-read
/// so the physical value, never the stale plan, repairs the mirror. Fetch
/// failures propagate so recovery clearance stays blocked while the physical
/// state cannot be checked (fail closed).
public struct RecoveryObservationService: Sendable {
    private enum ObservationAdmission {
        case ignore
        case resolved(ObservedWorkOutcome)
        case observe(MusicDatabaseTrackID)
    }

    private let verifier: any MusicAppVerifying

    public init(verifier: any MusicAppVerifying) {
        self.verifier = verifier
    }

    public func observeOutcomes(for items: [RunWorkItem]) async throws -> [UUID: ObservedWorkOutcome] {
        var outcomes: [UUID: ObservedWorkOutcome] = [:]
        var observationIDs: [UUID: MusicDatabaseTrackID] = [:]
        for item in items {
            switch Self.admission(for: item) {
            case .ignore:
                break
            case let .resolved(outcome):
                outcomes[item.id] = outcome
            case let .observe(databaseID):
                observationIDs[item.id] = databaseID
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
            outcomes[itemID] = Self.observedOutcome(for: item, track: tracksByID[databaseID])
        }
        return outcomes
    }

    private static func admission(for item: RunWorkItem) -> ObservationAdmission {
        switch item.state {
        case .outcome(.noFixNeeded) where item.writeChange == nil:
            observationAdmission(for: item)
        case .outcome:
            .ignore
        case .prepared:
            .resolved(ObservedWorkOutcome(outcome: .skipped, observedValue: nil))
        case .attempting, .attempted:
            observationAdmission(for: item)
        }
    }

    private static func observationAdmission(for item: RunWorkItem) -> ObservationAdmission {
        guard case let .track(identity) = item.target,
              let databaseID = identity.appleScriptID.flatMap(MusicDatabaseTrackID.init(rawValue:))
        else {
            return .resolved(.missingWriteIdentity)
        }
        return .observe(databaseID)
    }

    private static func observedOutcome(for item: RunWorkItem, track: Track?) -> ObservedWorkOutcome {
        guard let track else {
            return .missingTrack
        }
        guard case let .track(identity) = item.target,
              identity.matchesCurrentTrack(track, allowing: item.effectiveChange)
        else {
            return .identityMismatch
        }
        if item.state == .outcome(.noFixNeeded), item.writeChange == nil {
            return RecoveryObservation.noOpOutcome(for: item, observedTrack: track)
        }
        return RecoveryObservation.outcome(for: item, observedTrack: track)
    }
}
