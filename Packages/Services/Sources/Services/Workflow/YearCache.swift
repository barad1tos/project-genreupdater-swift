import Core
import Foundation

extension UpdateCoordinator {
    func cachedAlbumYear(for track: Track, context: YearDecisionContext) async -> AlbumCacheEntry? {
        let clock = ContinuousClock()
        let start = clock.now
        let entry = await lookupCachedAlbumYear(for: track, context: context)
        if let analytics {
            await analytics.record(
                .albumYearCacheRead,
                duration: start.duration(to: clock.now),
                outcome: .succeeded
            )
        }
        return entry
    }
}
