// APIOrchestrator+PendingVerification.swift -- Pending verification sync rules.

import Core

enum PendingVerificationSync {
    static func synchronize(
        service: (any PendingVerificationService)?,
        albumKey: (artist: String, album: String),
        currentLibraryYear: Int?,
        maxVerificationAttempts: Int,
        result: YearResult
    ) async {
        guard let service else { return }

        guard let resolvedYear = result.year else {
            await service.markForVerification(
                artist: albumKey.artist,
                album: albumKey.album,
                reason: "no_year_found",
                metadata: ["source": "api_orchestrator"],
                recheckDays: nil
            )
            return
        }

        if result.isDefinitive || resolvedYear == currentLibraryYear {
            await removeFromPendingAliases(service: service, albumKey: albumKey)
            return
        }

        let attemptCount = await service.getAttemptCount(artist: albumKey.artist, album: albumKey.album)
        if attemptCount >= maxVerificationAttempts {
            await removeFromPendingAliases(service: service, albumKey: albumKey)
            return
        }

        await service.markForVerification(
            artist: albumKey.artist,
            album: albumKey.album,
            reason: "no_year_found",
            metadata: [
                "candidate_year": String(resolvedYear),
                "confidence": String(result.confidence),
                "source": "api_orchestrator",
            ],
            recheckDays: nil
        )
    }

    private static func removeFromPendingAliases(
        service: any PendingVerificationService,
        albumKey: (artist: String, album: String)
    ) async {
        for identity in AlbumIdentity.lookupCandidates(artist: albumKey.artist, album: albumKey.album) {
            await service.removeFromPending(artist: identity.artist, album: identity.album)
        }
    }
}
