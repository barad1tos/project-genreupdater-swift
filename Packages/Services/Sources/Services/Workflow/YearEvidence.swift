import Core

struct ArtistYearEvidence {
    let activityPeriod: (start: Int?, end: Int?)?
    let startYear: Int?
    let country: String?
    let verificationAttempts: Int
}

extension UpdateCoordinator {
    func artistYearEvidence(
        normalizedArtist: String,
        track: Track
    ) async throws -> ArtistYearEvidence {
        let activityPeriod = await apiOrchestrator.getArtistActivityPeriod(
            normalizedArtist: normalizedArtist
        )
        try Task.checkCancellation()
        // Python parity (orchestrator.py:1079): the artist region rides
        // next to the activity period into release-country scoring.
        let country = await apiOrchestrator.getArtistRegion(normalizedArtist: normalizedArtist)
        try Task.checkCancellation()
        let attempts = await pendingVerificationService?.getAttemptCount(
            artist: track.albumIdentity.artist,
            album: track.albumIdentity.album
        ) ?? 0
        return ArtistYearEvidence(
            activityPeriod: activityPeriod,
            startYear: activityPeriod.start,
            country: country,
            verificationAttempts: attempts
        )
    }
}
