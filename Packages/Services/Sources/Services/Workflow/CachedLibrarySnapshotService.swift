// CachedLibrarySnapshotService.swift -- GRDB-backed library snapshot cache.

import Core
import CryptoKit
import Foundation

public actor CachedLibrarySnapshotService: LibrarySnapshotService {
    private let cache: any CacheService
    private let configuration: LibrarySnapshotConfig
    private let currentDate: @Sendable () -> Date
    private let libraryModificationDateProvider: (@Sendable () -> Date?)?
    private let namespace: String

    public var isEnabled: Bool {
        configuration.enabled
    }

    public init(
        cache: any CacheService,
        configuration: LibrarySnapshotConfig,
        currentDate: @escaping @Sendable () -> Date = { Date() },
        libraryModificationDateProvider: (@Sendable () -> Date?)? = nil
    ) {
        self.cache = cache
        self.configuration = configuration
        self.currentDate = currentDate
        self.libraryModificationDateProvider = libraryModificationDateProvider
        namespace = "library-snapshot:\(configuration.cacheFile)"
    }

    public func loadSnapshot() async throws -> [Track]? {
        guard isEnabled, await isSnapshotValid() else { return nil }
        return await cachedSnapshot()
    }

    public func clearSnapshot() async {
        await cache.invalidate(key: snapshotKey)
        await cache.invalidate(key: metadataKey)
    }

    @discardableResult
    public func saveSnapshot(_ tracks: [Track]) async throws -> String {
        let hash = try Self.snapshotHash(for: tracks)
        guard isEnabled else { return hash }

        let previousMetadata = await getSnapshotMetadata()
        let now = currentDate()
        let libraryModificationDate = libraryModificationDateProvider?() ?? now
        let ttl = snapshotTTL
        await cache.set(key: snapshotKey, value: tracks, ttl: ttl)
        try await updateSnapshotMetadata(LibraryCacheMetadata(
            trackCount: tracks.count,
            snapshotHash: hash,
            timestamp: now,
            libraryModificationDate: libraryModificationDate,
            lastForceScanDate: previousMetadata?.lastForceScanDate
        ))

        return hash
    }

    public func isSnapshotValid() async -> Bool {
        guard isEnabled,
              let metadata = await getSnapshotMetadata(),
              let snapshot = await cachedSnapshot()
        else { return false }

        guard metadata.trackCount == snapshot.count,
              let snapshotHash = try? Self.snapshotHash(for: snapshot),
              snapshotHash == metadata.snapshotHash
        else { return false }

        if let libraryModificationDateProvider {
            guard let libraryModificationDate = libraryModificationDateProvider() else { return false }
            if libraryModificationDate <= metadata.libraryModificationDate {
                return true
            }
        }

        return currentDate().timeIntervalSince(metadata.timestamp) <= snapshotTTL
    }

    public func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        await cache.get(key: metadataKey)
    }

    public func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws {
        guard isEnabled else { return }
        await cache.set(key: metadataKey, value: metadata, ttl: snapshotTTL)
    }

    public func getLibraryModificationDate() async throws -> Date {
        await getSnapshotMetadata()?.libraryModificationDate ?? .distantPast
    }

    private var snapshotKey: String {
        "\(namespace):tracks"
    }

    private var metadataKey: String {
        "\(namespace):metadata"
    }

    private var snapshotTTL: TimeInterval {
        TimeInterval(max(1, configuration.maxAgeHours)) * 3600
    }

    private func cachedSnapshot() async -> [Track]? {
        await cache.get(key: snapshotKey)
    }

    private static func snapshotHash(for tracks: [Track]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(tracks.sorted { $0.id < $1.id })
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
