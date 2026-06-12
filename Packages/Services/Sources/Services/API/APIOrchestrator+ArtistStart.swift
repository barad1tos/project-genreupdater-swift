// APIOrchestrator+ArtistStart.swift — Artist career start lookup parity

import Core
import Foundation
import OSLog

private enum ArtistStartYearCache {
    static let positiveTTL: TimeInterval = 31_536_000
    static let negativeTTL: TimeInterval = 86400
    static let notFoundSentinel = -1
}

extension APIOrchestrator {
    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async -> (start: Int?, end: Int?) {
        do {
            return try await musicBrainz.getArtistActivityPeriod(normalizedArtist: normalizedArtist)
        } catch {
            AppLogger.api.warning(
                "MusicBrainz artist activity lookup failed: \(error.localizedDescription, privacy: .public)"
            )
            return (nil, nil)
        }
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async -> Int? {
        let cacheKey = "artist_start_year:\(normalizedArtist)"
        if let cachedYear: Int = await cache?.get(key: cacheKey) {
            return cachedYear == ArtistStartYearCache.notFoundSentinel ? nil : cachedYear
        }

        let (musicBrainzStartYear, _) = await getArtistActivityPeriod(normalizedArtist: normalizedArtist)
        if let musicBrainzStartYear {
            await cache?.set(
                key: cacheKey,
                value: musicBrainzStartYear,
                ttl: ArtistStartYearCache.positiveTTL
            )
            return musicBrainzStartYear
        }

        do {
            if let appleMusicStartYear = try await appleMusic.getArtistStartYear(normalizedArtist: normalizedArtist) {
                await cache?.set(
                    key: cacheKey,
                    value: appleMusicStartYear,
                    ttl: ArtistStartYearCache.positiveTTL
                )
                return appleMusicStartYear
            }
        } catch {
            AppLogger.api.warning(
                "Apple Music artist start lookup failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        await cache?.set(
            key: cacheKey,
            value: ArtistStartYearCache.notFoundSentinel,
            ttl: ArtistStartYearCache.negativeTTL
        )
        return nil
    }
}
