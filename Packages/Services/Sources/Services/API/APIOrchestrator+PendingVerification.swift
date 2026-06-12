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
            await service.removeFromPending(artist: albumKey.artist, album: albumKey.album)
            return
        }

        let attemptCount = await service.getAttemptCount(artist: albumKey.artist, album: albumKey.album)
        if attemptCount >= maxVerificationAttempts {
            await service.removeFromPending(artist: albumKey.artist, album: albumKey.album)
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
}
