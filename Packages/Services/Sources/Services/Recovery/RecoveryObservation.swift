import Foundation

/// One observed physical outcome for a work item: the classification plus the
/// value actually seen in Music.app, preserved for the durable audit trail
/// (ADR 0006 "changed externally" evidence cannot be reconstructed later).
public struct ObservedWorkOutcome: Equatable, Sendable {
    public let outcome: WorkOutcome
    public let observedValue: String?

    public init(outcome: WorkOutcome, observedValue: String?) {
        self.outcome = outcome
        self.observedValue = observedValue
    }

    /// Audit note recorded on the closed work item, phrased per outcome so a
    /// closed ledger reads unambiguously.
    var detail: String? {
        switch outcome {
        case .written:
            observedValue.map { "Verified in Music.app: \($0)" }
        case .failed:
            observedValue.map { "Unchanged in Music.app: \($0)" }
        case .needsReview:
            observedValue.map { "Observed Music.app value: \($0)" }
                ?? "Track not found in Music.app"
        case .skipped, .dismissed, .noFixNeeded, .fixProposed, .deferred:
            nil
        }
    }
}

/// Classifies the physical Music.app state of one uncertain work item against
/// its planned change (ADR 0006: the observed Music.app state wins).
///
/// - `written`: the observed value equals the intended value — the physical
///   result is present, whether our dispatch or an equivalent edit landed it.
/// - `failed`: the observed value still equals the pre-write value (a nil
///   pre-write value is equated with an empty string) — the write never
///   landed; it must not be retried blindly (a fresh plan owns retries).
/// - `needsReview`: the track is absent, the planned change carries no
///   intended value, or a third value is present — an external change wins
///   and a person decides.
enum RecoveryObservation {
    static func outcome(for item: RunWorkItem, observedValue: String?) -> ObservedWorkOutcome {
        guard let observedValue else {
            return ObservedWorkOutcome(outcome: .needsReview, observedValue: nil)
        }
        guard let intended = item.change.newValue else {
            return ObservedWorkOutcome(outcome: .needsReview, observedValue: observedValue)
        }
        if observedValue == intended {
            return ObservedWorkOutcome(outcome: .written, observedValue: observedValue)
        }
        if observedValue == (item.change.oldValue ?? "") {
            return ObservedWorkOutcome(outcome: .failed, observedValue: observedValue)
        }
        return ObservedWorkOutcome(outcome: .needsReview, observedValue: observedValue)
    }
}
