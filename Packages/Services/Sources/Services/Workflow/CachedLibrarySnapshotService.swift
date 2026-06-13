// CachedLibrarySnapshotService.swift -- GRDB-backed library snapshot and delta cache.

import Core
import CryptoKit
import Foundation

public actor CachedLibrarySnapshotService: LibrarySnapshotService {
    private let cache: any CacheService
    private let configuration: LibrarySnapshotConfig
    private let currentDate: @Sendable () -> Date
    private let namespace: String

    public var isEnabled: Bool {
        configuration.enabled
    }

    public var isDeltaEnabled: Bool {
        configuration.enabled && configuration.deltaEnabled
    }

    public init(
        cache: any CacheService,
        configuration: LibrarySnapshotConfig,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.configuration = configuration
        self.currentDate = currentDate
        namespace = "library-snapshot:\(configuration.cacheFile)"
    }

    public func loadSnapshot() async throws -> [Track]? {
        guard isEnabled, await isSnapshotValid() else { return nil }
        return await cachedSnapshot()
    }

    @discardableResult
    public func saveSnapshot(_ tracks: [Track]) async throws -> String {
        let hash = try Self.snapshotHash(for: tracks)
        guard isEnabled else { return hash }

        let previousSnapshot = await cachedSnapshot()
        let now = currentDate()
        let ttl = snapshotTTL
        await cache.set(key: snapshotKey, value: tracks, ttl: ttl)
        try await updateSnapshotMetadata(LibraryCacheMetadata(
            trackCount: tracks.count,
            snapshotHash: hash,
            timestamp: now,
            libraryModificationDate: now
        ))

        if isDeltaEnabled, let previousSnapshot {
            await cache.set(
                key: deltaKey,
                value: Self.delta(from: previousSnapshot, to: tracks, timestamp: now),
                ttl: ttl
            )
        }

        return hash
    }

    public func isSnapshotValid() async -> Bool {
        guard isEnabled, let metadata = await getSnapshotMetadata() else { return false }
        let maxAge = TimeInterval(max(1, configuration.maxAgeHours)) * 3600
        return currentDate().timeIntervalSince(metadata.timestamp) <= maxAge
    }

    public func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        await cache.get(key: metadataKey)
    }

    public func updateSnapshotMetadata(_ metadata: LibraryCacheMetadata) async throws {
        guard isEnabled else { return }
        await cache.set(key: metadataKey, value: metadata, ttl: snapshotTTL)
    }

    public func loadDelta() async -> LibraryDeltaCache? {
        guard isDeltaEnabled else { return nil }
        return await cache.get(key: deltaKey)
    }

    public func saveDelta(_ delta: LibraryDeltaCache) async throws {
        guard isDeltaEnabled else { return }
        await cache.set(key: deltaKey, value: delta, ttl: snapshotTTL)
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

    private var deltaKey: String {
        "\(namespace):delta"
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

    private static func delta(
        from oldTracks: [Track],
        to newTracks: [Track],
        timestamp: Date
    ) -> LibraryDeltaCache {
        let oldByID = Dictionary(uniqueKeysWithValues: oldTracks.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newTracks.map { ($0.id, $0) })
        let oldIDs = Set(oldByID.keys)
        let newIDs = Set(newByID.keys)
        let commonIDs = oldIDs.intersection(newIDs)
        let modifiedIDs = commonIDs.filter { id in
            guard let oldTrack = oldByID[id], let newTrack = newByID[id] else { return false }
            return TrackFingerprint.hash(oldTrack) != TrackFingerprint.hash(newTrack)
        }

        return LibraryDeltaCache(
            addedIDs: newIDs.subtracting(oldIDs),
            removedIDs: oldIDs.subtracting(newIDs),
            modifiedIDs: Set(modifiedIDs),
            timestamp: timestamp
        )
    }
}
