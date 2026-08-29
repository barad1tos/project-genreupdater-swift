import Core
import Foundation

/// An actionable reason why physical Music.app evidence cannot safely
/// finalize a recovery item.
public enum RecoveryObservationIssue: Error, Equatable, Sendable {
    case observationUnavailable
    case trackMissing
    case trackIdentityChanged
    case writeIdentityMissing

    public var userGuidance: String {
        switch self {
        case .observationUnavailable:
            "Music.app metadata could not be observed; try recovery again"
        case .trackMissing:
            "The track is no longer available in Music.app"
        case .trackIdentityChanged:
            "Music.app now associates this database ID with a different track"
        case .writeIdentityMissing:
            "The recovery record has no valid Music.app track identity"
        }
    }
}

/// One observed physical outcome for a work item: the classification plus the
/// value actually seen in Music.app, preserved for the durable audit trail
/// (ADR 0006 "changed externally" evidence cannot be reconstructed later).
public struct ObservedWorkOutcome: Equatable, Sendable {
    public let outcome: WorkOutcome
    public let observedValue: String?
    private let detailOverride: String?
    let issue: RecoveryObservationIssue?
    let observedNoOpEffect: ObservedNoOpEffect?

    public init(outcome: WorkOutcome, observedValue: String?) {
        self.outcome = outcome
        self.observedValue = observedValue
        detailOverride = nil
        issue = nil
        observedNoOpEffect = nil
    }

    static let identityMismatch = Self(
        outcome: .needsReview,
        observedValue: nil,
        detailOverride: "Music.app track identity changed since the write was planned",
        issue: .trackIdentityChanged,
        observedNoOpEffect: nil
    )

    static let missingTrack = Self(
        outcome: .needsReview,
        observedValue: nil,
        detailOverride: "Track not found in Music.app",
        issue: .trackMissing,
        observedNoOpEffect: nil
    )

    static let missingWriteIdentity = Self(
        outcome: .needsReview,
        observedValue: nil,
        detailOverride: "Recovery item has no valid Music.app track identity",
        issue: .writeIdentityMissing,
        observedNoOpEffect: nil
    )

    private init(
        outcome: WorkOutcome,
        observedValue: String?,
        detailOverride: String?,
        issue: RecoveryObservationIssue?,
        observedNoOpEffect: ObservedNoOpEffect?
    ) {
        self.outcome = outcome
        self.observedValue = observedValue
        self.detailOverride = detailOverride
        self.issue = issue
        self.observedNoOpEffect = observedNoOpEffect
    }

    static func observedNoOp(_ effect: ObservedNoOpEffect, displayedValue: String?) -> Self {
        Self(
            outcome: .noFixNeeded,
            observedValue: displayedValue,
            detailOverride: nil,
            issue: nil,
            observedNoOpEffect: effect
        )
    }

    /// Audit note recorded on the closed work item, phrased per outcome so a
    /// closed ledger reads unambiguously.
    var detail: String? {
        if let detailOverride {
            return detailOverride
        }
        return switch outcome {
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

struct ObservedNoOpEffect: Equatable, Sendable {
    let value: String
    let albumArtistValue: String?
}

/// Classifies the physical Music.app state of one uncertain work item against
/// its persisted write effect (ADR 0006: the observed Music.app state wins).
///
/// - `written`: the observed value equals the intended value — the physical
///   result is present, whether our dispatch or an equivalent edit landed it.
/// - `failed`: the observed value still equals the pre-write value (a nil
///   pre-write value is equated with an empty string) — the write never
///   landed; it must not be retried blindly (a fresh plan owns retries).
/// - `needsReview`: the track is absent, the persisted write effect carries no
///   intended value, or a third value is present — an external change wins
///   and a person decides.
enum RecoveryObservation {
    static func outcome(for item: RunWorkItem, observedTrack: Track) -> ObservedWorkOutcome {
        let change = item.effectiveChange
        let property = MusicTrackProperty(changeType: change.changeType)
        let observedValue = property.currentValue(in: observedTrack)
        guard let albumArtistChange = change.albumArtistChange else {
            return classify(change, property: property, observedValue: observedValue)
        }
        let observedAlbumArtist = observedTrack.albumArtist ?? ""
        let combinedValue = "\(observedValue ?? "") (album artist: \(observedAlbumArtist))"
        if observedValue == change.newValue,
           observedAlbumArtist == albumArtistChange.newValue {
            return ObservedWorkOutcome(outcome: .written, observedValue: combinedValue)
        }
        if observedValue == (change.oldValue ?? ""),
           observedAlbumArtist == albumArtistChange.oldValue {
            return ObservedWorkOutcome(outcome: .failed, observedValue: combinedValue)
        }
        return ObservedWorkOutcome(outcome: .needsReview, observedValue: combinedValue)
    }

    static func noOpOutcome(for item: RunWorkItem, observedTrack: Track) -> ObservedWorkOutcome {
        let change = item.change
        let property = MusicTrackProperty(changeType: change.changeType)
        let observedValue = property.currentValue(in: observedTrack) ?? ""
        let persistedValue = change.changeType == .yearUpdate || change.changeType == .yearRevert
            ? String(observedTrack.year ?? MusicAppYear.missingValue)
            : observedValue
        let albumArtistValue = change.albumArtistChange == nil
            ? nil
            : observedTrack.albumArtist ?? ""
        let displayedValue = albumArtistValue.map { "\(observedValue) (album artist: \($0))" }
            ?? observedValue
        return .observedNoOp(
            ObservedNoOpEffect(value: persistedValue, albumArtistValue: albumArtistValue),
            displayedValue: displayedValue
        )
    }

    private static func classify(
        _ change: WorkChange,
        property: MusicTrackProperty,
        observedValue: String?
    ) -> ObservedWorkOutcome {
        guard let observedValue else {
            return ObservedWorkOutcome(outcome: .needsReview, observedValue: nil)
        }
        guard let intended = change.newValue else {
            return ObservedWorkOutcome(outcome: .needsReview, observedValue: observedValue)
        }
        if property.comparisonValue(observedValue) == property.comparisonValue(intended) {
            return ObservedWorkOutcome(outcome: .written, observedValue: observedValue)
        }
        if property.comparisonValue(observedValue) == property.comparisonValue(change.oldValue ?? "") {
            return ObservedWorkOutcome(outcome: .failed, observedValue: observedValue)
        }
        return ObservedWorkOutcome(outcome: .needsReview, observedValue: observedValue)
    }
}
