import Foundation
import Testing
@testable import Core
@testable import Services

/// Documents Swift-specific cache and sync intervals that intentionally differ
/// from Python config values. These are not parity gaps — they are
/// different-by-design decisions documented in the config crosswalk.
@Suite("Config parity — different-by-design intervals")
struct ConfigParityTests {
    @Test("Album year cache TTL defaults to 30 days (Swift-specific GRDB eviction)")
    func albumYearCacheTTLDefaultsToThirtyDays() {
        // Python uses cache_ttl_days: 36500 (effectively no eviction) for album years.
        // Swift uses GRDB with a 30-day TTL — a deliberate cache-eviction policy
        // that keeps the GRDB database bounded without requiring manual cleanup.
        let expectedTTL: TimeInterval = 30 * 24 * 3600
        #expect(GRDBCacheService.defaultAlbumYearTTL == expectedTTL)
    }

    @Test("Force metadata scan interval defaults to 7 days (Swift-specific feature)")
    func forceMetadataScanIntervalDefaultsToSevenDays() {
        // Python has no equivalent force-metadata-scan feature.
        // Swift auto-forces a metadata refresh when the last force scan is older
        // than 7 days. This is a Swift-specific library-sync optimization.
        let configuration = LibrarySyncRuntimeConfiguration()
        #expect(configuration.forceMetadataScanIntervalDays == 7)
    }
}
