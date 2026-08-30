import Core
import Foundation
import Testing
@testable import Services

@Suite("Best-effort invalidation")
struct BestEffortInvalidatorTests {
    @Test("Every conservative invalidation is attempted after earlier failures")
    func attemptsEveryInvalidation() async {
        let cache = FailingInvalidationCache()
        let snapshot = FailingInvalidationSnapshot()
        let invalidator = BestEffortInvalidator(cache: cache, snapshot: snapshot)

        await invalidator.invalidate(targets: [
            (artist: "First Artist", album: "First Album"),
            (artist: "Second Artist", album: "Second Album"),
        ])

        #expect(await cache.attempts == [
            .albumYear(artist: "First Artist", album: "First Album"),
            .apiResults(artist: "First Artist", album: "First Album"),
            .albumYear(artist: "Second Artist", album: "Second Album"),
            .apiResults(artist: "Second Artist", album: "Second Album"),
        ])
        #expect(await snapshot.clearCount == 1)
    }
}

private enum InvalidationAttempt: Equatable {
    case albumYear(artist: String, album: String)
    case apiResults(artist: String, album: String)
}

private enum InvalidationFailure: Error {
    case requested
}

private actor FailingInvalidationCache: CacheService {
    private(set) var attempts: [InvalidationAttempt] = []

    func initialize() async throws {
        // Intentionally empty: this cache double has no startup work.
    }
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {
        // Intentionally empty: generic cache writes are outside this invalidation test.
    }
    func invalidate(key _: String) async throws {
        // Intentionally empty: keyed invalidation is outside this album invalidation test.
    }
    func clear() async {
        // Intentionally empty: whole-cache clearing is outside this invalidation test.
    }
    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }
    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {
        // Intentionally empty: the test only observes invalidation attempts.
    }

    func invalidateAlbum(artist: String, album: String) async throws {
        attempts.append(.albumYear(artist: artist, album: album))
        throw InvalidationFailure.requested
    }

    func invalidateAllAlbumYears() async {
        // Intentionally empty: the test exercises per-album invalidation only.
    }
    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_: CachedAPIResult) async {
        // Intentionally empty: the test only observes API-result invalidation.
    }

    func invalidateCachedAPIResults(artist: String, album: String) async throws {
        attempts.append(.apiResults(artist: artist, album: album))
        throw InvalidationFailure.requested
    }

    func syncToDisk() async throws {
        // Intentionally empty: this in-memory double has nothing to persist.
    }
}

private actor FailingInvalidationSnapshot: LibrarySnapshotService {
    let isEnabled = true
    private(set) var clearCount = 0

    func loadSnapshot() async throws -> [Track]? {
        nil
    }
    func saveSnapshot(_: [Track]) async throws -> String {
        "snapshot"
    }

    func clearSnapshot() async throws {
        clearCount += 1
        throw InvalidationFailure.requested
    }

    func isSnapshotValid() async -> Bool {
        false
    }
    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        nil
    }
    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {
        // Intentionally empty: snapshot metadata is outside this clear-failure test.
    }
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }
}
