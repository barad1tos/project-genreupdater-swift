# Phase 4: API Clients + Cache — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement MusicBrainz, Discogs, and Apple Music API clients with rate limiting, GRDB caching, and orchestrator for parallel multi-source queries.

**Architecture:** Each API client is a `Sendable struct` conforming to `ExternalAPIService` protocol (Core). A shared `TokenBucketRateLimiter` actor (configurable per API) enforces rate limits. `APIOrchestrator` actor coordinates parallel queries via `async let`. GRDB cache (Phase 2A stub) gets extended with bulk ops and cache statistics.

**Tech Stack:** URLSession (Foundation), MusicKit, GRDB 7.x, Keychain Services, Swift Testing

**Design decisions:** MusicBrainz JSON format (`&fmt=json`), sequential build order (MB → Discogs → MusicKit → Orchestrator), Keychain for Discogs PAT, single generic `TokenBucketRateLimiter` actor, NetworkReachability deferred to Phase 5.

---

## Task 1: TokenBucketRateLimiter

Implements the `RateLimiter` protocol from `Core/Models/Protocols.swift:315-337`.
One generic actor, configured per API: `TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(1))` for MusicBrainz, `TokenBucketRateLimiter(maxTokens: 60, refillInterval: .seconds(60))` for Discogs.

**Files:**
- Create: `Packages/Services/Sources/Services/API/TokenBucketRateLimiter.swift`
- Test: `Packages/Services/Tests/ServicesTests/TokenBucketRateLimiterTests.swift`

**Step 1: Write the failing test**

```swift
// TokenBucketRateLimiterTests.swift
import Testing
import Foundation
@testable import Services
@testable import Core

@Suite("TokenBucketRateLimiter")
struct TokenBucketRateLimiterTests {

    @Test("Acquire returns zero wait when tokens available")
    func acquireWithTokens() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 5, refillInterval: .seconds(1))
        let wait = await limiter.acquire()
        #expect(wait == .zero)
    }

    @Test("Acquire waits when no tokens available")
    func acquireWaitsWhenEmpty() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(1))
        let wait1 = await limiter.acquire()
        #expect(wait1 == .zero)
        let wait2 = await limiter.acquire()
        #expect(wait2 > .zero)
    }

    @Test("Release returns a token to the bucket")
    func releaseReturnsToken() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(60))
        _ = await limiter.acquire()
        await limiter.release()
        let wait = await limiter.acquire()
        #expect(wait == .zero)
    }

    @Test("Stats track total requests and wait time")
    func statsTracking() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 2, refillInterval: .seconds(1))
        _ = await limiter.acquire()
        _ = await limiter.acquire()
        let stats = await limiter.getStats()
        #expect(stats.totalRequests == 2)
        #expect(stats.currentTokens == 0)
    }

    @Test("Tokens refill after interval passes")
    func tokenRefill() async throws {
        let limiter = TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .milliseconds(50)
        )
        _ = await limiter.acquire()
        try await Task.sleep(for: .milliseconds(100))
        let wait = await limiter.acquire()
        #expect(wait == .zero)
    }

    @Test("Cannot exceed maxTokens via release")
    func releaseDoesNotExceedMax() async throws {
        let limiter = TokenBucketRateLimiter(maxTokens: 1, refillInterval: .seconds(60))
        await limiter.release()
        await limiter.release()
        let stats = await limiter.getStats()
        #expect(stats.currentTokens == 1)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter TokenBucketRateLimiterTests 2>&1 | tail -20`
Expected: Compilation error — `TokenBucketRateLimiter` not found

**Step 3: Write minimal implementation**

```swift
// TokenBucketRateLimiter.swift
import Core
import Foundation

/// Token bucket rate limiter for API calls.
///
/// Configured per API: MusicBrainz (1 token/sec), Discogs (60 tokens/min).
/// Thread-safe via actor isolation.
public actor TokenBucketRateLimiter: RateLimiter {
    private let maxTokens: Int
    private let refillInterval: Duration
    private var currentTokens: Int
    private var lastRefill: ContinuousClock.Instant
    private var totalRequests: Int = 0
    private var totalWaitTime: Duration = .zero

    public init(maxTokens: Int, refillInterval: Duration) {
        self.maxTokens = maxTokens
        self.refillInterval = refillInterval
        self.currentTokens = maxTokens
        self.lastRefill = .now
    }

    public func acquire() async -> Duration {
        refillTokens()
        totalRequests += 1

        if currentTokens > 0 {
            currentTokens -= 1
            return .zero
        }

        let waitTime = refillInterval
        totalWaitTime += waitTime
        try? await Task.sleep(for: waitTime)
        refillTokens()
        currentTokens = max(currentTokens - 1, 0)
        return waitTime
    }

    public func release() {
        currentTokens = min(currentTokens + 1, maxTokens)
    }

    public func getStats() -> RateLimiterStats {
        RateLimiterStats(
            totalRequests: totalRequests,
            totalWaitTime: totalWaitTime,
            currentTokens: currentTokens
        )
    }

    private func refillTokens() {
        let now = ContinuousClock.Instant.now
        let elapsed = now - lastRefill

        guard elapsed >= refillInterval else { return }

        let periods = Int(elapsed / refillInterval)
        if periods > 0 {
            currentTokens = min(currentTokens + periods, maxTokens)
            lastRefill = now
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter TokenBucketRateLimiterTests 2>&1 | tail -20`
Expected: All 6 tests pass

**Step 5: Commit**

```
feat(services): add TokenBucketRateLimiter

actor-based token bucket for API rate limiting

- Configurable maxTokens + refillInterval
- MusicBrainz: 1 req/sec, Discogs: 60 req/min
- Stats tracking (totalRequests, waitTime)
- 6 tests covering acquire/release/refill/stats
```

---

## Task 2: MusicBrainz DTO Models [DONE]

Codable DTOs for MusicBrainz JSON API responses. Separate file keeps client clean.

**Files:**
- Create: `Packages/Services/Sources/Services/API/MusicBrainzModels.swift`

**Step 1: Write the DTO types**

```swift
// MusicBrainzModels.swift
import Foundation

// MARK: - Release Group Search Response

/// Top-level response from `/ws/2/release-group?query=...&fmt=json`.
struct MBReleaseGroupSearchResponse: Codable, Sendable {
    let releaseGroups: [MBReleaseGroup]

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

/// A MusicBrainz release group (album).
struct MBReleaseGroup: Codable, Sendable {
    let id: String
    let title: String
    let primaryType: String?
    let firstReleaseDate: String?
    let tags: [MBTag]?
    let genres: [MBGenre]?

    enum CodingKeys: String, CodingKey {
        case id, title, tags, genres
        case primaryType = "primary-type"
        case firstReleaseDate = "first-release-date"
    }

    /// Extract year from first-release-date (format: "YYYY" or "YYYY-MM-DD").
    var releaseYear: Int? {
        guard let dateStr = firstReleaseDate,
              dateStr.count >= 4,
              let year = Int(dateStr.prefix(4)),
              year > 0 else {
            return nil
        }
        return year
    }
}

/// A MusicBrainz tag (user-submitted).
struct MBTag: Codable, Sendable {
    let name: String
    let count: Int
}

/// A MusicBrainz genre (curated).
struct MBGenre: Codable, Sendable {
    let name: String
    let count: Int
}

// MARK: - Artist Lookup Response

/// Response from `/ws/2/artist/{mbid}?fmt=json`.
struct MBArtist: Codable, Sendable {
    let id: String
    let name: String
    let lifeSpan: MBLifeSpan?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case lifeSpan = "life-span"
    }
}

/// Life span of an artist (begin/end years).
struct MBLifeSpan: Codable, Sendable {
    let begin: String?
    let end: String?
    let ended: Bool?

    var beginYear: Int? {
        guard let begin, begin.count >= 4 else { return nil }
        return Int(begin.prefix(4))
    }

    var endYear: Int? {
        guard let end, end.count >= 4 else { return nil }
        return Int(end.prefix(4))
    }
}

// MARK: - Artist Search Response

/// Top-level response from `/ws/2/artist?query=...&fmt=json`.
struct MBArtistSearchResponse: Codable, Sendable {
    let artists: [MBArtist]
}
```

**Step 2: Run build to verify compilation**

Run: `cd Packages/Services && swift build 2>&1 | tail -10`
Expected: Build succeeded

**Step 3: Commit**

```
feat(services): add MusicBrainz DTO models

Codable structs for JSON API responses

- MBReleaseGroup with year extraction
- MBArtist with life-span parsing
- MBTag/MBGenre for genre data
```

---

## Task 3: MusicBrainzClient [DONE]

`Sendable struct` conforming to `ExternalAPIService`. Uses URLSession + JSON Codable.
Rate limited at 1 req/sec. Required User-Agent header.

**Files:**
- Create: `Packages/Services/Sources/Services/API/MusicBrainzClient.swift`
- Test: `Packages/Services/Tests/ServicesTests/MusicBrainzClientTests.swift`

**Step 1: Write the failing tests**

```swift
// MusicBrainzClientTests.swift
import Testing
import Foundation
@testable import Services
@testable import Core

@Suite("MusicBrainzClient")
struct MusicBrainzClientTests {

    // MARK: - JSON Parsing

    @Test("Parse release group search response")
    func parseReleaseGroupResponse() throws {
        let json = """
        {
            "release-groups": [
                {
                    "id": "abc-123",
                    "title": "Ride the Lightning",
                    "primary-type": "Album",
                    "first-release-date": "1984-07-27",
                    "tags": [{"name": "thrash metal", "count": 15}],
                    "genres": [{"name": "metal", "count": 8}]
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: json
        )
        #expect(response.releaseGroups.count == 1)
        #expect(response.releaseGroups[0].releaseYear == 1984)
        #expect(response.releaseGroups[0].title == "Ride the Lightning")
        #expect(response.releaseGroups[0].tags?.first?.name == "thrash metal")
    }

    @Test("Parse artist lookup response with life-span")
    func parseArtistResponse() throws {
        let json = """
        {
            "id": "def-456",
            "name": "Metallica",
            "type": "Group",
            "life-span": {
                "begin": "1981-10",
                "end": null,
                "ended": false
            }
        }
        """.data(using: .utf8)!

        let artist = try JSONDecoder().decode(MBArtist.self, from: json)
        #expect(artist.name == "Metallica")
        #expect(artist.lifeSpan?.beginYear == 1981)
        #expect(artist.lifeSpan?.endYear == nil)
    }

    @Test("Release year extraction handles partial dates")
    func releaseYearPartialDate() {
        let group = MBReleaseGroup(
            id: "test",
            title: "Test",
            primaryType: "Album",
            firstReleaseDate: "1984",
            tags: nil,
            genres: nil
        )
        #expect(group.releaseYear == 1984)
    }

    @Test("Release year extraction handles nil date")
    func releaseYearNilDate() {
        let group = MBReleaseGroup(
            id: "test",
            title: "Test",
            primaryType: nil,
            firstReleaseDate: nil,
            tags: nil,
            genres: nil
        )
        #expect(group.releaseYear == nil)
    }

    // MARK: - URL Building

    @Test("buildReleaseGroupSearchURL encodes query correctly")
    func buildSearchURL() throws {
        let url = MusicBrainzClient.buildReleaseGroupSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        )
        #expect(url != nil)
        let urlString = url!.absoluteString
        #expect(urlString.contains("fmt=json"))
        #expect(urlString.contains("release-group"))
        #expect(urlString.contains("Iron%20Maiden"))
    }

    @Test("buildArtistSearchURL encodes query correctly")
    func buildArtistSearchURL() throws {
        let url = MusicBrainzClient.buildArtistSearchURL(
            artist: "Motörhead"
        )
        #expect(url != nil)
        let urlString = url!.absoluteString
        #expect(urlString.contains("fmt=json"))
        #expect(urlString.contains("artist"))
    }

    // MARK: - Error Handling

    @Test("Client creates correct User-Agent header")
    func userAgentHeader() {
        let client = MusicBrainzClient()
        let request = client.makeRequest(for: URL(string: "https://example.com")!)
        #expect(request.value(forHTTPHeaderField: "User-Agent") != nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")!
            .contains("GenreUpdater"))
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter MusicBrainzClientTests 2>&1 | tail -20`
Expected: Compilation error — `MusicBrainzClient` not found

**Step 3: Write implementation**

```swift
// MusicBrainzClient.swift
import Core
import Foundation
import OSLog

/// MusicBrainz API client for album year and artist data.
///
/// Uses JSON format (`&fmt=json`) instead of default XML.
/// Rate limited at 1 request/second per MusicBrainz policy.
/// Requires User-Agent header with app name and contact.
///
/// Endpoints:
/// - Release group search: album year, genres/tags
/// - Artist lookup: activity period (life-span)
public struct MusicBrainzClient: ExternalAPIService, Sendable {
    private static let baseURL = "https://musicbrainz.org/ws/2"
    private static let userAgent = "GenreUpdater/1.0 (https://github.com/barad1tos/project-genreupdater-swift)"

    private let session: URLSession
    private let rateLimiter: TokenBucketRateLimiter
    private let log = AppLogger.api

    public init(
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil
    ) {
        self.session = session
        self.rateLimiter = rateLimiter ?? TokenBucketRateLimiter(
            maxTokens: 1,
            refillInterval: .seconds(1)
        )
    }

    // MARK: - ExternalAPIService

    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult {
        guard let url = Self.buildReleaseGroupSearchURL(
            artist: artist,
            album: album
        ) else {
            return YearResult()
        }

        let data = try await fetchWithRateLimit(url: url)
        let response = try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: data
        )

        guard let bestMatch = response.releaseGroups.first,
              let year = bestMatch.releaseYear else {
            return YearResult()
        }

        let confidence = bestMatch.primaryType == "Album" ? 80 : 60
        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: confidence,
            yearScores: [year: confidence]
        )
    }

    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async throws -> (start: Int?, end: Int?) {
        guard let url = Self.buildArtistSearchURL(
            artist: normalizedArtist
        ) else {
            return (nil, nil)
        }

        let data = try await fetchWithRateLimit(url: url)
        let response = try JSONDecoder().decode(
            MBArtistSearchResponse.self,
            from: data
        )

        guard let artist = response.artists.first else {
            return (nil, nil)
        }

        return (artist.lifeSpan?.beginYear, artist.lifeSpan?.endYear)
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        let (start, _) = try await getArtistActivityPeriod(
            normalizedArtist: normalizedArtist
        )
        return start
    }

    public func initialize(force: Bool) async throws {}
    public func close() async {}

    // MARK: - URL Builders (internal for testing)

    static func buildReleaseGroupSearchURL(
        artist: String,
        album: String
    ) -> URL? {
        var components = URLComponents(
            string: "\(baseURL)/release-group"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "query",
                value: "artist:\"\(artist)\" AND release:\"\(album)\""
            ),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        return components?.url
    }

    static func buildArtistSearchURL(artist: String) -> URL? {
        var components = URLComponents(
            string: "\(baseURL)/artist"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "query",
                value: "artist:\"\(artist)\""
            ),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return components?.url
    }

    // MARK: - Internal (package-visible for testing)

    func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Private

    private func fetchWithRateLimit(url: URL) async throws -> Data {
        let waitTime = await rateLimiter.acquire()
        if waitTime > .zero {
            log.debug("Rate limited, waited \(waitTime)")
        }

        let request = makeRequest(for: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MusicBrainzError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 400:
            throw MusicBrainzError.badRequest
        case 503:
            throw MusicBrainzError.serviceUnavailable
        default:
            throw MusicBrainzError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Errors

public enum MusicBrainzError: Error, Sendable {
    case invalidResponse
    case badRequest
    case serviceUnavailable
    case httpError(Int)
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter MusicBrainzClientTests 2>&1 | tail -20`
Expected: All 6 tests pass (JSON parsing + URL building + User-Agent — no network calls)

**Step 5: Run full Services test suite**

Run: `cd Packages/Services && swift test 2>&1 | tail -20`
Expected: All tests pass (existing + new)

**Step 6: Commit**

```
feat(services): add MusicBrainzClient

JSON API client for album year + artist data

- Release group search (year, genres, tags)
- Artist lookup (activity period/life-span)
- Rate limited via TokenBucketRateLimiter
- 6 tests (JSON parsing, URL building, headers)
```

---

## Task 4: Discogs DTO Models

Codable DTOs for Discogs REST API responses.

**Files:**
- Create: `Packages/Services/Sources/Services/API/DiscogsModels.swift`

**Step 1: Write the DTO types**

```swift
// DiscogsModels.swift
import Foundation

// MARK: - Search Response

/// Top-level response from `/database/search`.
struct DiscogsSearchResponse: Codable, Sendable {
    let results: [DiscogsSearchResult]
    let pagination: DiscogsPagination?
}

/// A search result from Discogs.
struct DiscogsSearchResult: Codable, Sendable {
    let id: Int
    let title: String
    let year: String?
    let type: String
    let masterID: Int?
    let masterURL: String?
    let genre: [String]?
    let style: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, type, genre, style
        case masterID = "master_id"
        case masterURL = "master_url"
    }

    var releaseYear: Int? {
        guard let year else { return nil }
        return Int(year)
    }
}

/// Pagination info from Discogs API.
struct DiscogsPagination: Codable, Sendable {
    let page: Int
    let pages: Int
    let perPage: Int
    let items: Int

    enum CodingKeys: String, CodingKey {
        case page, pages, items
        case perPage = "per_page"
    }
}

// MARK: - Master Release Response

/// Response from `/masters/{id}`.
struct DiscogsMasterRelease: Codable, Sendable {
    let id: Int
    let title: String
    let year: Int?
    let genres: [String]?
    let styles: [String]?
    let artists: [DiscogsArtistRef]?
}

/// Artist reference within a release.
struct DiscogsArtistRef: Codable, Sendable {
    let id: Int
    let name: String
}

// MARK: - Artist Response

/// Response from `/artists/{id}`.
struct DiscogsArtist: Codable, Sendable {
    let id: Int
    let name: String
    let profile: String?
    let members: [DiscogsArtistRef]?
}
```

**Step 2: Run build to verify compilation**

Run: `cd Packages/Services && swift build 2>&1 | tail -10`
Expected: Build succeeded

**Step 3: Commit**

```
feat(services): add Discogs DTO models

Codable structs for Discogs REST API

- DiscogsSearchResult with year + genres
- DiscogsMasterRelease with styles
- DiscogsArtist with profile
```

---

## Task 5: Keychain Helper [DONE]

Minimal Keychain wrapper for storing/retrieving the Discogs Personal Access Token.

**Files:**
- Create: `Packages/Services/Sources/Services/API/KeychainHelper.swift`
- Test: `Packages/Services/Tests/ServicesTests/KeychainHelperTests.swift`

**Step 1: Write the failing test**

```swift
// KeychainHelperTests.swift
import Testing
import Foundation
@testable import Services

@Suite("KeychainHelper")
struct KeychainHelperTests {

    private let testService = "com.genreupdater.test"
    private let testAccount = "discogs-token-test"

    @Test("Save and retrieve token roundtrip")
    func saveAndRetrieve() throws {
        let helper = KeychainHelper()
        try helper.save(
            token: "test-token-123",
            service: testService,
            account: testAccount
        )
        let retrieved = try helper.retrieve(
            service: testService,
            account: testAccount
        )
        #expect(retrieved == "test-token-123")

        // Cleanup
        try? helper.delete(
            service: testService,
            account: testAccount
        )
    }

    @Test("Retrieve returns nil for missing token")
    func retrieveMissing() throws {
        let helper = KeychainHelper()
        let result = try helper.retrieve(
            service: testService,
            account: "nonexistent-\(UUID().uuidString)"
        )
        #expect(result == nil)
    }

    @Test("Delete removes token")
    func deleteToken() throws {
        let helper = KeychainHelper()
        try helper.save(
            token: "to-delete",
            service: testService,
            account: testAccount
        )
        try helper.delete(
            service: testService,
            account: testAccount
        )
        let result = try helper.retrieve(
            service: testService,
            account: testAccount
        )
        #expect(result == nil)
    }

    @Test("Save overwrites existing token")
    func saveOverwrites() throws {
        let helper = KeychainHelper()
        try helper.save(
            token: "old-token",
            service: testService,
            account: testAccount
        )
        try helper.save(
            token: "new-token",
            service: testService,
            account: testAccount
        )
        let result = try helper.retrieve(
            service: testService,
            account: testAccount
        )
        #expect(result == "new-token")

        try? helper.delete(
            service: testService,
            account: testAccount
        )
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter KeychainHelperTests 2>&1 | tail -20`
Expected: Compilation error — `KeychainHelper` not found

**Step 3: Write implementation**

```swift
// KeychainHelper.swift
import Foundation
import Security

/// Minimal Keychain wrapper for storing API tokens.
///
/// Used by DiscogsClient to store/retrieve Personal Access Token.
/// Thread-safe: Security framework handles concurrency internally.
public struct KeychainHelper: Sendable {
    public init() {}

    public func save(
        token: String,
        service: String,
        account: String
    ) throws {
        let data = Data(token.utf8)

        // Delete existing item first (upsert pattern)
        try? delete(service: service, account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func retrieve(
        service: String,
        account: String
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.retrieveFailed(status)
        }
    }

    public func delete(
        service: String,
        account: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound
        else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

public enum KeychainError: Error, Sendable {
    case saveFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter KeychainHelperTests 2>&1 | tail -20`
Expected: All 4 tests pass

**Step 5: Commit**

```
feat(services): add KeychainHelper for API tokens

Minimal Keychain wrapper for Discogs PAT

- Save/retrieve/delete with upsert pattern
- Typed errors for each operation
- 4 tests with cleanup
```

---

## Task 6: DiscogsClient [DONE]

`Sendable struct` conforming to `ExternalAPIService`. Uses URLSession + JSON Codable.
Rate limited at 60 req/min. Auth via Keychain-stored Personal Access Token.

**Files:**
- Create: `Packages/Services/Sources/Services/API/DiscogsClient.swift`
- Test: `Packages/Services/Tests/ServicesTests/DiscogsClientTests.swift`

**Step 1: Write the failing tests**

```swift
// DiscogsClientTests.swift
import Testing
import Foundation
@testable import Services
@testable import Core

@Suite("DiscogsClient")
struct DiscogsClientTests {

    // MARK: - JSON Parsing

    @Test("Parse search response with master release")
    func parseSearchResponse() throws {
        let json = """
        {
            "results": [
                {
                    "id": 1234,
                    "title": "Iron Maiden - Powerslave",
                    "year": "1984",
                    "type": "master",
                    "master_id": 5678,
                    "master_url": "https://api.discogs.com/masters/5678",
                    "genre": ["Rock"],
                    "style": ["Heavy Metal", "NWOBHM"]
                }
            ],
            "pagination": {
                "page": 1,
                "pages": 1,
                "per_page": 50,
                "items": 1
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: json
        )
        #expect(response.results.count == 1)
        #expect(response.results[0].releaseYear == 1984)
        #expect(response.results[0].style?.contains("Heavy Metal") == true)
    }

    @Test("Parse master release response")
    func parseMasterRelease() throws {
        let json = """
        {
            "id": 5678,
            "title": "Powerslave",
            "year": 1984,
            "genres": ["Rock"],
            "styles": ["Heavy Metal", "NWOBHM"],
            "artists": [
                {"id": 1, "name": "Iron Maiden"}
            ]
        }
        """.data(using: .utf8)!

        let master = try JSONDecoder().decode(
            DiscogsMasterRelease.self,
            from: json
        )
        #expect(master.year == 1984)
        #expect(master.genres?.contains("Rock") == true)
        #expect(master.artists?.first?.name == "Iron Maiden")
    }

    @Test("Search result handles missing year")
    func searchResultMissingYear() {
        let result = DiscogsSearchResult(
            id: 1,
            title: "Test",
            year: nil,
            type: "master",
            masterID: nil,
            masterURL: nil,
            genre: nil,
            style: nil
        )
        #expect(result.releaseYear == nil)
    }

    // MARK: - URL Building

    @Test("buildSearchURL encodes query correctly")
    func buildSearchURL() throws {
        let url = DiscogsClient.buildSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        )
        #expect(url != nil)
        let urlString = url!.absoluteString
        #expect(urlString.contains("database/search"))
        #expect(urlString.contains("type=master"))
    }

    @Test("buildMasterURL uses correct ID")
    func buildMasterURL() {
        let url = DiscogsClient.buildMasterURL(masterID: 5678)
        #expect(url != nil)
        #expect(url!.absoluteString.contains("masters/5678"))
    }

    // MARK: - Auth Header

    @Test("Client sets Authorization header when token provided")
    func authHeader() {
        let client = DiscogsClient(token: "test-token-123")
        let request = client.makeRequest(
            for: URL(string: "https://example.com")!
        )
        #expect(request.value(forHTTPHeaderField: "Authorization")
            == "Discogs token=test-token-123")
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter DiscogsClientTests 2>&1 | tail -20`
Expected: Compilation error — `DiscogsClient` not found

**Step 3: Write implementation**

```swift
// DiscogsClient.swift
import Core
import Foundation
import OSLog

/// Discogs API client for album year and genre data.
///
/// Auth: Personal Access Token from Keychain.
/// Rate limited at 60 requests/minute per Discogs policy.
///
/// Endpoints:
/// - Database search: find master releases
/// - Master release details: year, genres, styles
public struct DiscogsClient: ExternalAPIService, Sendable {
    private static let baseURL = "https://api.discogs.com"
    private static let keychainService = "com.genreupdater.discogs"
    private static let keychainAccount = "personal-access-token"

    private let session: URLSession
    private let rateLimiter: TokenBucketRateLimiter
    private let token: String?
    private let log = AppLogger.api

    /// Create with explicit token (for testing or direct config).
    public init(
        token: String? = nil,
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil
    ) {
        self.token = token
        self.session = session
        self.rateLimiter = rateLimiter ?? TokenBucketRateLimiter(
            maxTokens: 60,
            refillInterval: .seconds(60)
        )
    }

    /// Create with token from Keychain.
    public static func fromKeychain(
        session: URLSession = .shared,
        rateLimiter: TokenBucketRateLimiter? = nil
    ) throws -> DiscogsClient {
        let keychain = KeychainHelper()
        let token = try keychain.retrieve(
            service: keychainService,
            account: keychainAccount
        )
        return DiscogsClient(
            token: token,
            session: session,
            rateLimiter: rateLimiter
        )
    }

    /// Save a token to Keychain for future use.
    public static func saveToken(_ token: String) throws {
        let keychain = KeychainHelper()
        try keychain.save(
            token: token,
            service: keychainService,
            account: keychainAccount
        )
    }

    // MARK: - ExternalAPIService

    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult {
        guard token != nil else {
            throw DiscogsError.noToken
        }

        guard let url = Self.buildSearchURL(
            artist: artist,
            album: album
        ) else {
            return YearResult()
        }

        let data = try await fetchWithRateLimit(url: url)
        let response = try JSONDecoder().decode(
            DiscogsSearchResponse.self,
            from: data
        )

        // Prefer master release for original year
        if let master = response.results.first(where: {
            $0.masterID != nil
        }),
            let masterID = master.masterID
        {
            return try await fetchMasterYear(masterID: masterID)
        }

        // Fallback to search result year
        guard let first = response.results.first,
              let year = first.releaseYear else {
            return YearResult()
        }

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: 60,
            yearScores: [year: 60]
        )
    }

    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async throws -> (start: Int?, end: Int?) {
        // Discogs doesn't expose structured activity periods
        (nil, nil)
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        nil
    }

    public func initialize(force: Bool) async throws {}
    public func close() async {}

    // MARK: - URL Builders (internal for testing)

    static func buildSearchURL(
        artist: String,
        album: String
    ) -> URL? {
        var components = URLComponents(
            string: "\(baseURL)/database/search"
        )
        components?.queryItems = [
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "release_title", value: album),
            URLQueryItem(name: "type", value: "master"),
            URLQueryItem(name: "per_page", value: "5"),
        ]
        return components?.url
    }

    static func buildMasterURL(masterID: Int) -> URL? {
        URL(string: "\(baseURL)/masters/\(masterID)")
    }

    func makeRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token {
            request.setValue(
                "Discogs token=\(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "GenreUpdater/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    // MARK: - Private

    private func fetchMasterYear(masterID: Int) async throws -> YearResult {
        guard let url = Self.buildMasterURL(masterID: masterID)
        else {
            return YearResult()
        }

        let data = try await fetchWithRateLimit(url: url)
        let master = try JSONDecoder().decode(
            DiscogsMasterRelease.self,
            from: data
        )

        guard let year = master.year else {
            return YearResult()
        }

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: 75,
            yearScores: [year: 75]
        )
    }

    private func fetchWithRateLimit(url: URL) async throws -> Data {
        let waitTime = await rateLimiter.acquire()
        if waitTime > .zero {
            log.debug("Discogs rate limited, waited \(waitTime)")
        }

        let request = makeRequest(for: url)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscogsError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 401:
            throw DiscogsError.unauthorized
        case 429:
            throw DiscogsError.rateLimited
        default:
            throw DiscogsError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Errors

public enum DiscogsError: Error, Sendable {
    case noToken
    case invalidResponse
    case unauthorized
    case rateLimited
    case httpError(Int)
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter DiscogsClientTests 2>&1 | tail -20`
Expected: All 6 tests pass

**Step 5: Commit**

```
feat(services): add DiscogsClient with Keychain auth

REST API client for album year + genre data

- Master release search for original year
- Keychain-based PAT storage
- Rate limited at 60 req/min
- 6 tests (JSON parsing, URL building, auth header)
```

**Implementation notes (2026-02-20):**
- `DiscogsError` enum includes `LocalizedError` conformance with `errorDescription`
- `inclusive_language` SwiftLint annotations applied for Discogs API terminology ("master release")
- `KeychainHelper` committed separately as prerequisite

---

## Task 7: AppleMusicSearchClient [DONE]

Uses MusicKit `CatalogSearchRequest` for genre data from Apple Music catalog.
No rate limiting needed (Apple manages internally).

**Files:**
- Create: `Packages/Services/Sources/Services/API/AppleMusicSearchClient.swift`
- Test: `Packages/Services/Tests/ServicesTests/AppleMusicSearchClientTests.swift`

**Step 1: Write the test (limited — MusicKit requires entitlement)**

MusicKit's `CatalogSearchRequest` requires a running app with MusicKit entitlement. Unit tests can only verify the non-MusicKit logic (DTO mapping, error handling). Integration tests deferred to Phase 7 (launch testing).

```swift
// AppleMusicSearchClientTests.swift
import Testing
import Foundation
@testable import Services
@testable import Core

@Suite("AppleMusicSearchClient")
struct AppleMusicSearchClientTests {

    @Test("Client conforms to ExternalAPIService")
    func conformsToProtocol() {
        let client = AppleMusicSearchClient()
        #expect(client is any ExternalAPIService)
    }

    @Test("getAlbumYear returns empty result when MusicKit unavailable")
    func albumYearWithoutEntitlement() async throws {
        let client = AppleMusicSearchClient()
        // In test context, MusicKit authorization is not available.
        // Client should handle this gracefully.
        let result = try await client.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        // Without entitlement, expect empty or low-confidence result
        #expect(result.confidence <= 50)
    }

    @Test("getArtistActivityPeriod returns nil pair")
    func artistActivityPeriod() async throws {
        let client = AppleMusicSearchClient()
        let (start, end) = try await client.getArtistActivityPeriod(
            normalizedArtist: "Test"
        )
        // MusicKit doesn't expose artist activity periods
        #expect(start == nil)
        #expect(end == nil)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter AppleMusicSearchClientTests 2>&1 | tail -20`
Expected: Compilation error — `AppleMusicSearchClient` not found

**Step 3: Write implementation**

```swift
// AppleMusicSearchClient.swift
import Core
import Foundation
import MusicKit
import OSLog

/// Apple Music catalog search for genre data.
///
/// Uses MusicKit's `CatalogSearchRequest` for native access.
/// No rate limiting needed — Apple manages internally.
/// Requires MusicKit entitlement in the app target.
public struct AppleMusicSearchClient: ExternalAPIService, Sendable {
    private let log = AppLogger.api

    public init() {}

    // MARK: - ExternalAPIService

    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult {
        let authStatus = await requestAuthorization()
        guard authStatus == .authorized else {
            log.info("MusicKit not authorized, skipping Apple Music search")
            return YearResult()
        }

        var request = MusicCatalogSearchRequest(
            term: "\(artist) \(album)",
            types: [Album.self]
        )
        request.limit = 5

        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch {
            log.error("MusicKit search failed: \(error, privacy: .public)")
            return YearResult()
        }

        guard let bestMatch = response.albums.first else {
            return YearResult()
        }

        guard let releaseDate = bestMatch.releaseDate else {
            return YearResult()
        }

        let year = Calendar.current.component(.year, from: releaseDate)
        let genres = bestMatch.genreNames

        var metadata: [Int: Int] = [:]
        metadata[year] = 70

        log.debug("Apple Music: \(artist, privacy: .private) - \(album, privacy: .private) → \(year, privacy: .public), genres: \(genres.joined(separator: ", "), privacy: .private)")

        return YearResult(
            year: year,
            isDefinitive: false,
            confidence: 70,
            yearScores: metadata
        )
    }

    public func getArtistActivityPeriod(
        normalizedArtist: String
    ) async throws -> (start: Int?, end: Int?) {
        // MusicKit doesn't expose artist activity periods
        (nil, nil)
    }

    public func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        nil
    }

    public func initialize(force: Bool) async throws {}
    public func close() async {}

    // MARK: - Private

    private func requestAuthorization() async -> MusicAuthorization.Status {
        await MusicAuthorization.request()
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter AppleMusicSearchClientTests 2>&1 | tail -20`
Expected: All 3 tests pass

**Step 5: Commit**

```
feat(services): add AppleMusicSearchClient

MusicKit-based catalog search for genres

- CatalogSearchRequest for album + year
- Genre extraction from Apple Music catalog
- Graceful fallback when not authorized
- 3 tests (protocol conformance, no-entitlement)
```

**Implementation notes (2026-02-20):**
- MusicKit authorization check via `MusicAuthorization.request()` before any catalog request
- All user data (artist, album, genres) logged with `.private` privacy
- `getArtistActivityPeriod` and `getArtistStartYear` return nil stubs — MusicKit lacks this data
- `initialize(force:)` and `close()` are no-ops — MusicKit manages its own lifecycle
- Tests verify graceful degradation without entitlement (confidence <= 50)

---

## Task 8: Extend GRDBCacheService (bulk ops + statistics)

Add bulk operations and cache statistics to the existing GRDB stub.

**Files:**
- Modify: `Packages/Services/Sources/Services/Persistence/GRDB/GRDBCacheService.swift`
- Modify: `Packages/Services/Tests/ServicesTests/GRDBCacheServiceTests.swift`

**Step 1: Write the failing tests**

Add to existing `GRDBCacheServiceTests.swift`:

```swift
// Add to GRDBCacheServiceTests.swift

    // MARK: - Bulk Operations

    @Test("Bulk store album years")
    func bulkStoreAlbumYears() async throws {
        let service = try await makeService()

        let entries = [
            ("Metallica", "Master of Puppets", 1986, 95),
            ("Metallica", "Ride the Lightning", 1984, 90),
            ("Iron Maiden", "Powerslave", 1984, 85),
        ]

        await service.bulkStoreAlbumYears(entries)

        let entry1 = await service.getAlbumYear(
            artist: "Metallica",
            album: "Master of Puppets"
        )
        let entry2 = await service.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave"
        )
        #expect(entry1?.year == 1986)
        #expect(entry2?.year == 1984)
    }

    @Test("Bulk invalidate album years")
    func bulkInvalidateAlbumYears() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(
            artist: "A",
            album: "X",
            year: 2020,
            confidence: 80
        )
        await service.storeAlbumYear(
            artist: "B",
            album: "Y",
            year: 2021,
            confidence: 80
        )

        await service.bulkInvalidateAlbums(
            [("A", "X"), ("B", "Y")]
        )

        let a = await service.getAlbumYear(artist: "A", album: "X")
        let b = await service.getAlbumYear(artist: "B", album: "Y")
        #expect(a == nil)
        #expect(b == nil)
    }

    // MARK: - Cache Statistics

    @Test("Cache statistics track entry counts")
    func cacheStatistics() async throws {
        let service = try await makeService()

        await service.storeAlbumYear(
            artist: "A",
            album: "X",
            year: 2020,
            confidence: 80
        )
        await service.set(key: "k1", value: "v1", ttl: nil)

        let stats = await service.getCacheStatistics()
        #expect(stats.albumYearCount >= 1)
        #expect(stats.genericCacheCount >= 1)
    }

    @Test("Cache statistics report expired entries")
    func cacheStatisticsExpired() async throws {
        let service = try await makeService()

        // Set with expired TTL
        await service.set(key: "expired", value: "old", ttl: -1)
        await service.set(key: "valid", value: "new", ttl: 3600)

        let stats = await service.getCacheStatistics()
        #expect(stats.genericCacheCount == 2)
        #expect(stats.expiredCount >= 1)
    }
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter GRDBCacheServiceTests 2>&1 | tail -20`
Expected: Compilation error — `bulkStoreAlbumYears`, `getCacheStatistics` not found

**Step 3: Add implementation to GRDBCacheService**

Add to `GRDBCacheService.swift`:

```swift
    // MARK: - Bulk Operations

    /// Store multiple album year entries in a single transaction.
    public func bulkStoreAlbumYears(
        _ entries: [(artist: String, album: String, year: Int, confidence: Int)]
    ) async {
        do {
            try await dbWriter.write { database in
                for entry in entries {
                    let cacheEntry = AlbumCacheEntry(
                        artist: entry.artist,
                        album: entry.album,
                        year: entry.year,
                        confidence: entry.confidence,
                        timestamp: .now
                    )
                    try AlbumYearRow(from: cacheEntry).save(database)
                }
            }
            log.info("Bulk stored \(entries.count, privacy: .public) album years")
        } catch {
            log.error("bulkStoreAlbumYears failed: \(error, privacy: .public)")
        }
    }

    /// Invalidate multiple album year entries in a single transaction.
    public func bulkInvalidateAlbums(
        _ albums: [(artist: String, album: String)]
    ) async {
        do {
            try await dbWriter.write { database in
                for (artist, album) in albums {
                    try database.execute(
                        sql: "DELETE FROM album_years WHERE artist = ? AND album = ?",
                        arguments: [artist, album]
                    )
                }
            }
        } catch {
            log.error("bulkInvalidateAlbums failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Cache Statistics

    /// Aggregate statistics about cache contents.
    public func getCacheStatistics() async -> CacheStatistics {
        do {
            return try await dbWriter.read { database in
                let albumYearCount = try AlbumYearRow.fetchCount(database)
                let apiResultCount = try CachedAPIRow.fetchCount(database)
                let genericCount = try GenericCacheRow.fetchCount(database)

                let expiredGeneric = try GenericCacheRow
                    .filter(Column("ttl") != nil)
                    .fetchAll(database)
                    .filter(\.isExpired)
                    .count

                return CacheStatistics(
                    albumYearCount: albumYearCount,
                    apiResultCount: apiResultCount,
                    genericCacheCount: genericCount,
                    expiredCount: expiredGeneric
                )
            }
        } catch {
            log.error("getCacheStatistics failed: \(error, privacy: .public)")
            return CacheStatistics(
                albumYearCount: 0,
                apiResultCount: 0,
                genericCacheCount: 0,
                expiredCount: 0
            )
        }
    }
```

Add `CacheStatistics` struct (same file, at the bottom):

```swift
/// Aggregate cache statistics.
public struct CacheStatistics: Sendable {
    public let albumYearCount: Int
    public let apiResultCount: Int
    public let genericCacheCount: Int
    public let expiredCount: Int
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter GRDBCacheServiceTests 2>&1 | tail -20`
Expected: All tests pass (existing 13 + 4 new = 17)

**Step 5: Commit**

```
feat(services): extend GRDBCacheService with bulk ops
and statistics

- bulkStoreAlbumYears in single transaction
- bulkInvalidateAlbums in single transaction
- getCacheStatistics with entry counts + expiry
- 4 new tests
```

---

## Task 9: APIOrchestrator

Actor that coordinates parallel API calls via `async let`. Aggregates results from MusicBrainz, Discogs, and Apple Music. Timeout per source. Fallback when a source is unavailable.

**Files:**
- Create: `Packages/Services/Sources/Services/API/APIOrchestrator.swift`
- Test: `Packages/Services/Tests/ServicesTests/APIOrchestratorTests.swift`

**Step 1: Write the failing tests**

```swift
// APIOrchestratorTests.swift
import Testing
import Foundation
@testable import Services
@testable import Core

// MARK: - Mock API Service

/// Mock ExternalAPIService for testing orchestration logic.
struct MockAPIService: ExternalAPIService {
    let yearResult: YearResult
    let shouldThrow: Bool
    let delay: Duration

    init(
        yearResult: YearResult = YearResult(),
        shouldThrow: Bool = false,
        delay: Duration = .zero
    ) {
        self.yearResult = yearResult
        self.shouldThrow = shouldThrow
        self.delay = delay
    }

    func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async throws -> YearResult {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if shouldThrow {
            throw MockAPIError.intentional
        }
        return yearResult
    }

    func getArtistActivityPeriod(
        normalizedArtist: String
    ) async throws -> (start: Int?, end: Int?) {
        (nil, nil)
    }

    func getArtistStartYear(
        normalizedArtist: String
    ) async throws -> Int? {
        nil
    }

    func initialize(force: Bool) async throws {}
    func close() async {}
}

enum MockAPIError: Error {
    case intentional
}

// MARK: - Tests

@Suite("APIOrchestrator")
struct APIOrchestratorTests {

    @Test("Aggregates results from multiple sources")
    func aggregateResults() async throws {
        let mb = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 80,
                yearScores: [1984: 80]
            )
        )
        let dc = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 75,
                yearScores: [1984: 75]
            )
        )
        let am = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 70,
                yearScores: [1984: 70]
            )
        )

        let orchestrator = APIOrchestrator(
            musicBrainz: mb,
            discogs: dc,
            appleMusic: am
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Iron Maiden",
            album: "Powerslave",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1984)
        #expect(result.confidence > 80)
    }

    @Test("Continues when one source fails")
    func fallbackOnFailure() async throws {
        let mb = MockAPIService(
            yearResult: YearResult(
                year: 1986,
                confidence: 80,
                yearScores: [1986: 80]
            )
        )
        let dc = MockAPIService(shouldThrow: true)
        let am = MockAPIService(shouldThrow: true)

        let orchestrator = APIOrchestrator(
            musicBrainz: mb,
            discogs: dc,
            appleMusic: am
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Metallica",
            album: "Master of Puppets",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 1986)
        #expect(result.confidence == 80)
    }

    @Test("Returns empty when all sources fail")
    func allSourcesFail() async throws {
        let orchestrator = APIOrchestrator(
            musicBrainz: MockAPIService(shouldThrow: true),
            discogs: MockAPIService(shouldThrow: true),
            appleMusic: MockAPIService(shouldThrow: true)
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Nobody",
            album: "Nothing",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == nil)
        #expect(result.confidence == 0)
    }

    @Test("Handles timeout for slow sources")
    func timeoutSlowSource() async throws {
        let fast = MockAPIService(
            yearResult: YearResult(
                year: 2000,
                confidence: 80,
                yearScores: [2000: 80]
            )
        )
        let slow = MockAPIService(
            yearResult: YearResult(
                year: 2001,
                confidence: 90,
                yearScores: [2001: 90]
            ),
            delay: .seconds(10)
        )

        let orchestrator = APIOrchestrator(
            musicBrainz: fast,
            discogs: slow,
            appleMusic: MockAPIService(shouldThrow: true),
            timeout: .seconds(1)
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2000)
    }

    @Test("Best year selected by highest combined score")
    func bestYearByScore() async throws {
        let mb = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 80,
                yearScores: [1984: 80]
            )
        )
        let dc = MockAPIService(
            yearResult: YearResult(
                year: 1985,
                confidence: 60,
                yearScores: [1985: 60]
            )
        )
        let am = MockAPIService(
            yearResult: YearResult(
                year: 1984,
                confidence: 70,
                yearScores: [1984: 70]
            )
        )

        let orchestrator = APIOrchestrator(
            musicBrainz: mb,
            discogs: dc,
            appleMusic: am
        )

        let result = await orchestrator.getAlbumYear(
            artist: "Test",
            album: "Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        // 1984 has combined score 150 (80+70) vs 1985 score 60
        #expect(result.year == 1984)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cd Packages/Services && swift test --filter APIOrchestratorTests 2>&1 | tail -20`
Expected: Compilation error — `APIOrchestrator` not found

**Step 3: Write implementation**

```swift
// APIOrchestrator.swift
import Core
import Foundation
import OSLog

/// Coordinates parallel API calls across MusicBrainz, Discogs, and Apple Music.
///
/// Uses `async let` for concurrent queries. Each source has an independent
/// timeout. Results are aggregated by year score — the year with the highest
/// combined confidence across all sources wins.
public actor APIOrchestrator {
    private let musicBrainz: any ExternalAPIService
    private let discogs: any ExternalAPIService
    private let appleMusic: any ExternalAPIService
    private let timeout: Duration
    private let log = AppLogger.api

    public init(
        musicBrainz: any ExternalAPIService,
        discogs: any ExternalAPIService,
        appleMusic: any ExternalAPIService,
        timeout: Duration = .seconds(15)
    ) {
        self.musicBrainz = musicBrainz
        self.discogs = discogs
        self.appleMusic = appleMusic
        self.timeout = timeout
    }

    /// Query all sources in parallel, aggregate results by year score.
    public func getAlbumYear(
        artist: String,
        album: String,
        currentLibraryYear: Int?,
        earliestTrackAddedYear: Int?
    ) async -> YearResult {
        async let mbResult = fetchWithTimeout(source: "musicbrainz") {
            try await self.musicBrainz.getAlbumYear(
                artist: artist,
                album: album,
                currentLibraryYear: currentLibraryYear,
                earliestTrackAddedYear: earliestTrackAddedYear
            )
        }

        async let dcResult = fetchWithTimeout(source: "discogs") {
            try await self.discogs.getAlbumYear(
                artist: artist,
                album: album,
                currentLibraryYear: currentLibraryYear,
                earliestTrackAddedYear: earliestTrackAddedYear
            )
        }

        async let amResult = fetchWithTimeout(source: "applemusic") {
            try await self.appleMusic.getAlbumYear(
                artist: artist,
                album: album,
                currentLibraryYear: currentLibraryYear,
                earliestTrackAddedYear: earliestTrackAddedYear
            )
        }

        let results = await [mbResult, dcResult, amResult]
        return aggregateResults(results)
    }

    // MARK: - Private

    private func fetchWithTimeout(
        source: String,
        operation: @Sendable () async throws -> YearResult
    ) async -> YearResult {
        do {
            return try await withThrowingTaskGroup(
                of: YearResult.self
            ) { group in
                group.addTask {
                    try await operation()
                }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    throw CancellationError()
                }

                guard let result = try await group.next() else {
                    return YearResult()
                }
                group.cancelAll()
                return result
            }
        } catch {
            if !(error is CancellationError) {
                log.error("\(source, privacy: .public) failed: \(error, privacy: .public)")
            } else {
                log.warning("\(source, privacy: .public) timed out")
            }
            return YearResult()
        }
    }

    private func aggregateResults(
        _ results: [YearResult]
    ) -> YearResult {
        var combinedScores: [Int: Int] = [:]

        for result in results {
            for (year, score) in result.yearScores {
                combinedScores[year, default: 0] += score
            }
        }

        guard let (bestYear, bestScore) = combinedScores.max(
            by: { $0.value < $1.value }
        ) else {
            return YearResult()
        }

        let sourceCount = results.filter { $0.year != nil }.count
        let isDefinitive = sourceCount >= 2 && results.filter({
            $0.year == bestYear
        }).count >= 2

        return YearResult(
            year: bestYear,
            isDefinitive: isDefinitive,
            confidence: min(bestScore, 100),
            yearScores: combinedScores
        )
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd Packages/Services && swift test --filter APIOrchestratorTests 2>&1 | tail -20`
Expected: All 5 tests pass

**Step 5: Run full Services test suite**

Run: `cd Packages/Services && swift test 2>&1 | tail -20`
Expected: All tests pass

**Step 6: Commit**

```
feat(services): add APIOrchestrator for parallel
multi-source queries

Actor coordinating MB + Discogs + Apple Music

- async let parallel queries with per-source timeout
- Year aggregation by combined confidence score
- Graceful fallback when sources fail
- 5 tests with MockAPIService
```

---

## Task 10: Update task file and docs

Update Phase 4 task file, CLAUDE.md, and sync to Obsidian.

**Files:**
- Modify: `docs/tasks/phase-4-api-cache.md` — check off completed deliverables
- Modify: `CLAUDE.md` — update Phase Status, add new files
- Sync: Copy updated docs to Obsidian vault

**Step 1: Update task file checkboxes**

Check off each deliverable as implemented. Mark NetworkReachability as deferred.

**Step 2: Update CLAUDE.md Phase Status**

Update Phase 4 row from "Planned" to "🔄 Active" with file list.

**Step 3: Copy to Obsidian**

```bash
cp docs/tasks/phase-4-api-cache.md "/Users/cloud/Obsidian/Development/GenreUpdater/Tasks/"
```

**Step 4: Commit**

```
docs: update Phase 4 task tracking and CLAUDE.md
```

---

## Verification Checklist (after all tasks)

```bash
# 1. Build all packages
cd Packages/Core && swift build
cd Packages/Services && swift build

# 2. Run all tests
cd Packages/Core && swift test
cd Packages/Services && swift test

# 3. Full Xcode build
xcodebuild build -project GenreUpdater.xcodeproj -scheme GenreUpdater \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet

# 4. Lint
swiftlint lint --strict Packages/Services/Sources
swiftformat Packages/Services/Sources --lint

# 5. Verify file count
find Packages/Services/Sources/Services/API -name "*.swift" | wc -l
# Expected: 7 files

# 6. Verify test count
cd Packages/Services && swift test 2>&1 | grep "Test run"
# Expected: ~50+ tests, 0 failures
```

## File Summary

| # | File | Action | Task |
|---|------|--------|------|
| 1 | `Services/API/TokenBucketRateLimiter.swift` | Create | 1 |
| 2 | `Services/API/MusicBrainzModels.swift` | Create | 2 |
| 3 | `Services/API/MusicBrainzClient.swift` | Create | 3 |
| 4 | `Services/API/DiscogsModels.swift` | Create | 4 |
| 5 | `Services/API/KeychainHelper.swift` | Create | 5 |
| 6 | `Services/API/DiscogsClient.swift` | Create | 6 |
| 7 | `Services/API/AppleMusicSearchClient.swift` | Create | 7 |
| 8 | `Services/Persistence/GRDB/GRDBCacheService.swift` | Modify | 8 |
| 9 | `Services/API/APIOrchestrator.swift` | Create | 9 |
| 10 | `docs/tasks/phase-4-api-cache.md` | Modify | 10 |
| 11 | `CLAUDE.md` | Modify | 10 |

**Test files (6):**
| # | Test File | Tests | Task |
|---|-----------|-------|------|
| 1 | `TokenBucketRateLimiterTests.swift` | 6 | 1 |
| 2 | `MusicBrainzClientTests.swift` | 6 | 3 |
| 3 | `DiscogsClientTests.swift` | 6 | 6 |
| 4 | `KeychainHelperTests.swift` | 4 | 5 |
| 5 | `AppleMusicSearchClientTests.swift` | 3 | 7 |
| 6 | `APIOrchestratorTests.swift` | 5 | 9 |
| 7 | `GRDBCacheServiceTests.swift` (extend) | +4 | 8 |
| — | **Total new tests** | **34** | — |
