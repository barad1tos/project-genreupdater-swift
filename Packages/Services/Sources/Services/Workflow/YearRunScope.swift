import Core

struct APIYearDecision: Sendable {
    let determination: YearDeterminationResult
    let sourceLabel: String
    let usesLegacyResult: Bool
}

/// Shares album-level year decisions and deduplicates safety marks within one preview or write run.
///
/// Create one scope per multi-track run and pass the same instance to every `updateTrack` call in that run.
/// Track-specific proposal construction and safety evaluation still occur per track.
public actor YearRunScope {
    private var markedAlbumKeys: Set<String> = []
    private var albumDecisions: [String: APIYearDecision] = [:]

    public init() {
        // Each run starts without recorded album effects.
    }

    func recordSafetyIssue(for track: Track) -> Bool {
        markedAlbumKeys.insert(AlbumIdentity.key(for: track)).inserted
    }

    func decision(for track: Track) -> APIYearDecision? {
        albumDecisions[AlbumIdentity.key(for: track)]
    }

    func resolve(
        _ proposedDecision: APIYearDecision,
        for track: Track
    ) -> (decision: APIYearDecision, appliesAlbumEffects: Bool) {
        let key = AlbumIdentity.key(for: track)
        if let decision = albumDecisions[key] {
            return (decision, false)
        }
        albumDecisions[key] = proposedDecision
        return (proposedDecision, true)
    }
}
