import Core
import CryptoKit
import Foundation

/// A non-empty MusicKit catalog identifier used only for presentation reads.
public struct CatalogTrackID: Equatable, Hashable, Sendable {
    public let displayValue: String

    public init?(displayValue: String) {
        guard !displayValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.displayValue = displayValue
    }
}

/// One presentation-only MusicKit catalog row.
public struct CatalogTrack: Equatable, Sendable {
    public let id: CatalogTrackID
    public let title: String
    public let artist: String
    public let album: String
    public let albumArtist: String?
    public let genres: [String]
    public let dates: CatalogDates

    public init(
        id: CatalogTrackID,
        title: String,
        artist: String,
        album: String,
        albumArtist: String?,
        genres: [String],
        dates: CatalogDates
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genres = genres
        self.dates = dates
    }
}

/// Temporal metadata exposed by a MusicKit catalog row.
public struct CatalogDates: Equatable, Sendable {
    public let releaseYear: Int?
    public let dateAdded: Date?

    public init(releaseYear: Int?, dateAdded: Date?) {
        self.releaseYear = releaseYear
        self.dateAdded = dateAdded
    }
}

/// One in-memory presentation snapshot of the MusicKit song catalog.
public struct CatalogSnapshot: Equatable, Sendable {
    public let tracks: [CatalogTrack]
    public let capturedAt: Date
    public let fingerprint: CatalogFingerprint

    public init(tracks: [CatalogTrack], capturedAt: Date = Date()) {
        self.tracks = tracks
        self.capturedAt = capturedAt
        fingerprint = CatalogFingerprint.make(tracks: tracks)
    }
}

/// Provenance of the catalog snapshot currently used for presentation.
public enum CatalogSnapshotSource: Equatable, Sendable {
    case live
    case persisted
}

/// A non-fatal problem attached to the catalog currently used for presentation.
public enum CatalogIssue: Equatable, Sendable {
    /// The live read failed, so the current snapshot may be stale or unavailable.
    case refreshFailed(message: String)
    /// The live read succeeded, but its snapshot could not be saved for a later launch.
    case persistenceFailed(message: String)
    /// The live read failed and the saved fallback could not be recovered.
    case recoveryFailed(message: String)

    public var message: String {
        switch self {
        case let .refreshFailed(message), let .persistenceFailed(message), let .recoveryFailed(message):
            message
        }
    }
}

/// Stable content identity for one complete MusicKit presentation snapshot.
public struct CatalogFingerprint: Equatable, Hashable, Sendable {
    public let rawValue: String

    static func make(tracks: [CatalogTrack]) -> Self {
        var payload = Data()
        for track in tracks.sorted(by: { $0.id.displayValue < $1.id.displayValue }) {
            append(track.id.displayValue, to: &payload)
            append(track.title, to: &payload)
            append(track.artist, to: &payload)
            append(track.album, to: &payload)
            append(track.albumArtist, to: &payload)
            for genre in track.genres.sorted() {
                append(genre, to: &payload)
            }
            append(track.genres.count, to: &payload)
            append(track.dates.releaseYear, to: &payload)
            append(track.dates.dateAdded?.timeIntervalSinceReferenceDate.bitPattern, to: &payload)
        }
        let digest = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return Self(rawValue: digest)
    }

    private static func append(_ value: String?, to payload: inout Data) {
        guard let value else {
            payload.append(0)
            return
        }
        payload.append(1)
        let bytes = Data(value.utf8)
        append(bytes.count, to: &payload)
        payload.append(bytes)
    }

    private static func append(_ value: Int?, to payload: inout Data) {
        guard let value else {
            payload.append(0)
            return
        }
        payload.append(1)
        var encoded = Int64(value).bigEndian
        withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt64?, to payload: inout Data) {
        guard let value else {
            payload.append(0)
            return
        }
        payload.append(1)
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
    }

    private static func append(_ value: Int, to payload: inout Data) {
        var encoded = UInt64(value).bigEndian
        withUnsafeBytes(of: &encoded) { payload.append(contentsOf: $0) }
    }
}

/// Narrow read capability for MusicKit-backed presentation catalog operations.
public protocol MusicCatalogReading: Actor {
    var isAuthorized: Bool { get async }

    func requestAuthorization() async throws
    func loadCatalog() async throws -> CatalogSnapshot
}

/// Measures catalog loads when analytics is installed without changing catalog routing.
public actor MeasuredMusicCatalog: MusicCatalogReading {
    private let base: any MusicCatalogReading
    private var analytics: (any AnalyticsService)?

    public init(base: any MusicCatalogReading, analytics: (any AnalyticsService)? = nil) {
        self.base = base
        self.analytics = analytics
    }

    public var isAuthorized: Bool {
        get async { await base.isAuthorized }
    }

    public func updateAnalytics(_ analytics: any AnalyticsService) {
        self.analytics = analytics
    }

    public func requestAuthorization() async throws {
        try await base.requestAuthorization()
    }

    public func loadCatalog() async throws -> CatalogSnapshot {
        guard let analytics else {
            return try await base.loadCatalog()
        }
        return try await analytics.measure(.musicAppFetch) {
            try await base.loadCatalog()
        }
    }
}
