import Core
import CryptoKit
import Foundation
import OSLog

/// A cached miss: the request failed after retries and the failure itself
/// is cached (Python request_executor parity — the eternal-negative wart
/// is the ported contract). Callers treat it as the fast network failure
/// it represents.
public enum RawAPIRequestCacheError: Error, Equatable {
    case cachedFailure
}

/// The stored entry: response bytes for a success, a marker for a miss.
private struct RawRequestEntry: Codable {
    let payload: Data?
}

/// The shared pre-limiter response cache all three API clients front their
/// HTTP fetches with (Python request_executor.execute_request parity):
/// a hit returns before auth, rate limiting, and the network; both
/// polarities share one TTL. Keys are order-insensitive over query items.
public struct RawAPIRequestCache: Sendable {
    private let cache: any CacheService
    private let ttl: TimeInterval

    public init(cache: any CacheService, ttl: TimeInterval) {
        self.cache = cache
        self.ttl = ttl
    }

    public func data(
        api: String,
        url: URL,
        fetch: @Sendable () async throws -> Data
    ) async throws -> Data {
        let key = Self.cacheKey(api: api, url: url)
        if let entry: RawRequestEntry = await cache.get(key: key) {
            guard let payload = entry.payload else {
                throw RawAPIRequestCacheError.cachedFailure
            }
            return payload
        }

        do {
            let payload = try await fetch()
            await cache.set(key: key, value: RawRequestEntry(payload: payload), ttl: ttl)
            return payload
        } catch is CancellationError {
            // A cancelled request says nothing about the endpoint.
            throw CancellationError()
        } catch {
            await cache.set(key: key, value: RawRequestEntry(payload: nil), ttl: ttl)
            throw error
        }
    }

    /// Deterministic, order-insensitive request identity (Python sorts
    /// params before hashing; reordered query items share one entry).
    static func cacheKey(api: String, url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let sortedQuery = (components?.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")
        let base = "\(components?.scheme ?? "")://\(components?.host ?? "")\(components?.path ?? "")"
        let canonical = "\(api)|\(base)?\(sortedQuery)"
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "raw_request:\(api):\(hex)"
    }
}
