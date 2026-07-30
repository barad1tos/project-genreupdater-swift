// PersistedPendingAlbumEntry.swift -- SwiftData model for pending year verification.

import Core
import Foundation
import SwiftData

/// Persistent representation of an album waiting for manual year verification.
@Model
public final class PersistedPendingAlbumEntry {
    @Attribute(.unique)
    public var entryID: String

    public var artist: String
    public var album: String
    public var reason: String
    public var attemptCount: Int
    public var lastAttempt: Date
    public var recheckInterval: TimeInterval
    public var metadataData: Data?

    public init(from entry: Core.PendingAlbumEntry) {
        entryID = entry.id
        artist = entry.artist
        album = entry.album
        reason = entry.reason
        attemptCount = entry.attemptCount
        lastAttempt = entry.lastAttempt
        recheckInterval = entry.recheckInterval
        metadataData = Self.encodeMetadata(entry.metadata)
    }
}

/// Singleton metadata record for pending verification state.
@Model
public final class PersistedPendingVerificationMetadata {
    @Attribute(.unique)
    public var metadataID: String

    public var lastAutoVerification: Date?

    public init(
        metadataID: String = "pending-verification",
        lastAutoVerification: Date? = nil
    ) {
        self.metadataID = metadataID
        self.lastAutoVerification = lastAutoVerification
    }
}

// MARK: - Conversion to/from Core.PendingAlbumEntry

extension PersistedPendingAlbumEntry {
    public func update(from entry: Core.PendingAlbumEntry) {
        artist = entry.artist
        album = entry.album
        reason = entry.reason
        attemptCount = entry.attemptCount
        lastAttempt = entry.lastAttempt
        recheckInterval = entry.recheckInterval
        metadataData = Self.encodeMetadata(entry.metadata)
    }

    public func toPendingAlbumEntry() -> Core.PendingAlbumEntry {
        Core.PendingAlbumEntry(
            id: entryID,
            artist: artist,
            album: album,
            reason: reason,
            retry: .init(
                attemptCount: attemptCount,
                lastAttempt: lastAttempt,
                recheckInterval: recheckInterval
            ),
            metadata: Self.decodeMetadata(metadataData)
        )
    }

    private static func encodeMetadata(_ metadata: [String: String]) -> Data? {
        guard !metadata.isEmpty else { return nil }
        return try? JSONEncoder().encode(metadata)
    }

    private static func decodeMetadata(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
