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

    func initialize() async throws {}
    func get<T: Codable & Sendable>(key _: String) async -> T? {
        nil
    }
    func set(key _: String, value _: some Codable & Sendable, ttl _: TimeInterval?) async {}
    func invalidate(key _: String) async throws {}
    func clear() async {}
    func getAlbumYear(artist _: String, album _: String) async -> AlbumCacheEntry? {
        nil
    }
    func storeAlbumYear(artist _: String, album _: String, year _: Int, confidence _: Int) async {}

    func invalidateAlbum(artist: String, album: String) async throws {
        attempts.append(.albumYear(artist: artist, album: album))
        throw InvalidationFailure.requested
    }

    func invalidateAllAlbumYears() async {}
    func getCachedAPIResult(artist _: String, album _: String, source _: String) async -> CachedAPIResult? {
        nil
    }
    func setCachedAPIResult(_: CachedAPIResult) async {}

    func invalidateCachedAPIResults(artist: String, album: String) async throws {
        attempts.append(.apiResults(artist: artist, album: album))
        throw InvalidationFailure.requested
    }

    func syncToDisk() async throws {}
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
    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {}
    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }
}
