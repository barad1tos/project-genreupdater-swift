// APIOrchestrator+PendingVerification.swift -- Pending verification sync rules.

import Core

enum PendingVerificationSync {
    static func synchronize(
        service: (any PendingVerificationService)?,
        albumKey: (artist: String, album: String),
        albumAliases: [(artist: String, album: String)] = [],
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

        if result.isDefinitive {
            await removeFromPendingAliases(service: service, albumKey: albumKey, albumAliases: albumAliases)
            return
        }

        if resolvedYear == currentLibraryYear {
            return
        }

        let attemptCount = await service.getAttemptCount(artist: albumKey.artist, album: albumKey.album)
        if attemptCount >= maxVerificationAttempts {
            await removeFromPendingAliases(service: service, albumKey: albumKey, albumAliases: albumAliases)
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
        albumKey: (artist: String, album: String),
        albumAliases: [(artist: String, album: String)]
    ) async {
        let pendingEntries = await service.getAllPendingAlbums()
        for target in removalTargets(
            albumKey: albumKey,
            albumAliases: albumAliases,
            pendingEntries: pendingEntries
        ) {
            await service.removeFromPending(artist: target.artist, album: target.album)
        }
    }

    private static func removalTargets(
        albumKey: (artist: String, album: String),
        albumAliases: [(artist: String, album: String)],
        pendingEntries: [PendingAlbumEntry]
    ) -> [(artist: String, album: String)] {
        var targetKeys = Set<String>()
        var seenKeys: Set<String> = []
        var targets: [(artist: String, album: String)] = []

        func appendTarget(artist: String, album: String) {
            targetKeys.formUnion(AlbumIdentity.lookupKeys(artist: artist, album: album))
            let key = AlbumIdentity.key(artist: artist, album: album)
            guard seenKeys.insert(key).inserted else { return }
            guard !hasProtectedPendingEntry(
                artist: artist,
                album: album,
                pendingEntries: pendingEntries
            ) else { return }
            targets.append((artist: artist, album: album))
        }

        for identity in AlbumIdentity.lookupCandidates(artist: albumKey.artist, album: albumKey.album) {
            appendTarget(artist: identity.artist, album: identity.album)
        }
        for alias in albumAliases {
            for identity in AlbumIdentity.lookupCandidates(artist: alias.artist, album: alias.album) {
                appendTarget(artist: identity.artist, album: identity.album)
            }
        }

        for entry in pendingEntries where shouldRemovePendingEntry(
            entry,
            targetKeys: targetKeys
        ) {
            appendTarget(artist: entry.artist, album: entry.album)
        }

        return targets
    }

    private static func shouldRemovePendingEntry(
        _ entry: PendingAlbumEntry,
        targetKeys: Set<String>
    ) -> Bool {
        guard isRemovablePendingEntry(entry) else { return false }

        let entryKeys = Set(AlbumIdentity.lookupKeys(artist: entry.artist, album: entry.album))
        return !targetKeys.isDisjoint(with: entryKeys)
    }

    private static func hasProtectedPendingEntry(
        artist: String,
        album: String,
        pendingEntries: [PendingAlbumEntry]
    ) -> Bool {
        let key = AlbumIdentity.key(artist: artist, album: album)
        return pendingEntries.contains { entry in
            AlbumIdentity.key(artist: entry.artist, album: entry.album) == key && !isRemovablePendingEntry(entry)
        }
    }

    private static func isRemovablePendingEntry(_ entry: PendingAlbumEntry) -> Bool {
        let normalizedReason = entry.reason
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return normalizedReason != "prerelease" && normalizedReason != "pre_release"
    }
}
