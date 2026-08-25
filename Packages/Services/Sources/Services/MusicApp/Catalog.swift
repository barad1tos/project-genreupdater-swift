import Core
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

    public init(tracks: [CatalogTrack]) {
        self.tracks = tracks
    }
}

/// Narrow read capability for MusicKit-backed presentation catalog operations.
public protocol MusicCatalogReading: Actor {
    var isAuthorized: Bool { get async }

    func requestAuthorization() async throws
    func loadCatalog(testArtists: [String]) async throws -> CatalogSnapshot
    func trackCount() async throws -> Int
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

    public func loadCatalog(testArtists: [String]) async throws -> CatalogSnapshot {
        guard let analytics else {
            return try await base.loadCatalog(testArtists: testArtists)
        }
        return try await analytics.measure(.musicAppFetch) {
            try await base.loadCatalog(testArtists: testArtists)
        }
    }

    public func trackCount() async throws -> Int {
        try await base.trackCount()
    }
}
