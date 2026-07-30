import Foundation

/// Classifies the physical Music.app state of one uncertain work item against
/// its planned change (ADR 0006: the observed Music.app state wins).
///
/// - `written`: the observed value equals the intended value — the physical
///   result is present, whether our dispatch or an equivalent edit landed it.
/// - `failed`: the observed value still equals the pre-write value — the write
///   never landed; it must not be retried blindly (a fresh plan owns retries).
/// - `needsReview`: the track is absent or carries a third value — an external
///   change wins and a person decides.
enum RecoveryObservation {
    static func outcome(for item: RunWorkItem, observedValue: String?) -> WorkOutcome {
        guard let observedValue else {
            return .needsReview
        }
        guard let intended = item.change.newValue else {
            return .needsReview
        }
        if observedValue == intended {
            return .written
        }
        if observedValue == (item.change.oldValue ?? "") {
            return .failed
        }
        return .needsReview
    }
}
