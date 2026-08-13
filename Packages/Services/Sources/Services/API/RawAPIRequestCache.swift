import Core
import CryptoKit
import Foundation
import OSLog

/// A cached miss. Reserved for entries written by a layer that KNOWS the
/// failure is final; this seam never writes one (see the type doc).
/// Callers treat it as the fast network failure it represents.
public enum RawAPIRequestCacheError: Error, Equatable {
    case cachedFailure
}

/// The stored entry: response bytes for a success, a marker for a miss.
private struct RawRequestEntry: Codable {
    let payload: Data?
    let storedAt: Date?

    init(payload: Data?, storedAt: Date = .now) {
        self.payload = payload
        self.storedAt = storedAt
    }

    private enum CodingKeys: String, CodingKey {
        case payload, storedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = try container.decodeIfPresent(Data.self, forKey: .payload)
        storedAt = try container.decodeIfPresent(Date.self, forKey: .storedAt)
    }
}

/// The shared pre-limiter response cache all three API clients front their
/// HTTP fetches with (Python request_executor.execute_request parity):
/// a hit returns before auth, rate limiting, and the network. Keys are
/// order-insensitive over query items.
///
/// Deliberate divergence: Python caches a failure ({}) because its retry
/// loop lives INSIDE execute_request, so a cached failure is always
/// post-retry. Swift's retry layer sits ABOVE this seam, so caching here
/// would freeze the FIRST transient 429/503 for the whole TTL — this
/// seam therefore never writes a miss. Only responses that parse as JSON
/// are stored, mirroring Python caching the parsed dict.
/// Persisted hits are also checked against the current TTL so a shorter policy
/// or Off takes effect without waiting for an older physical expiry.
public struct RawAPIRequestCache: Sendable {
    /// Raw bodies share the generic table's row budget with the derived
    /// caches (release candidates, artist regions). An iTunes search at
    /// limit=200 is hundreds of KB, base64-inflated — without a ceiling
    /// one library run would evict every derived entry.
    static let maximumCachedBodyBytes = 256 * 1024

    private let cache: any CacheService
    private let ttl: TimeInterval
    private let log = AppLogger.api

    public init(cache: any CacheService, ttl: TimeInterval) {
        self.cache = cache
        self.ttl = max(0, ttl)
    }

    public func data(
        api: String,
        url: URL,
        fetch: @Sendable () async throws -> Data
    ) async throws -> Data {
        let key = Self.cacheKey(api: api, url: url)
        if let entry: RawRequestEntry = await cache.get(key: key) {
            if isCurrent(entry) {
                guard let payload = entry.payload else {
                    throw RawAPIRequestCacheError.cachedFailure
                }
                return payload
            }
            await cache.invalidate(key: key)
        }

        let payload = try await fetch()
        // Python caches the PARSED response, so a truncated or HTML body
        // never becomes a cache entry; a JSON sanity check is the same
        // gate without decoding twice into client-specific types.
        guard (try? JSONSerialization.jsonObject(with: payload)) != nil else {
            log.warning("Raw response for \(api, privacy: .public) is not JSON; not cached")
            return payload
        }
        guard payload.count <= Self.maximumCachedBodyBytes else {
            log.debug("Raw response for \(api, privacy: .public) exceeds the cache ceiling; not cached")
            return payload
        }
        await cache.set(key: key, value: RawRequestEntry(payload: payload), ttl: ttl)
        return payload
    }

    private func isCurrent(_ entry: RawRequestEntry) -> Bool {
        guard ttl > 0, let storedAt = entry.storedAt else { return false }
        return Date.now.timeIntervalSince(storedAt) < ttl
    }

    /// Deterministic, order-insensitive request identity (Python sorts
    /// params before hashing; reordered query items share one entry).
    static func cacheKey(api: String, url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let sortedQuery = (components?.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
        let port = components?.port.map { ":\($0)" } ?? ""
        let base = "\(components?.scheme ?? "")://\(components?.host ?? "")\(port)\(components?.path ?? "")"
        let canonical = "\(api)|\(base)?\(sortedQuery)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "raw_request:\(api):\(hex)"
    }
}
