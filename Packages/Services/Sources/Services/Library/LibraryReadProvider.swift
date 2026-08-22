import Core
import Foundation

public struct LibraryReadRequest: Sendable, Equatable {
    public let testArtists: [String]
    /// When set, the read narrows to one album: a track belongs when any
    /// of its identity lookup keys (canonical, raw, split aliases) equals
    /// the target key — collaboration spellings stay admitted, which is
    /// what the retired artist-string narrowing could not do.
    public let albumIdentity: AlbumIdentity?

    public init(
        testArtists: [String] = [],
        albumIdentity: AlbumIdentity? = nil
    ) {
        self.testArtists = ArtistAllowList.normalized(testArtists)
        self.albumIdentity = albumIdentity
    }

    /// The single admission predicate every load path filters through:
    /// the artist allow-list keeps its veto, the album identity (when
    /// present) narrows membership.
    public func admits(_ track: Track) -> Bool {
        guard ArtistAllowList.containsNormalized(track, in: testArtists) else {
            return false
        }
        guard let albumIdentity else { return true }
        return AlbumIdentity.lookupKeys(for: track).contains(albumIdentity.key)
    }
}

public struct LibraryReadSnapshot: Sendable, Equatable {
    public let tracks: [Track]
    public let scannedAt: Date

    public init(tracks: [Track], scannedAt: Date) {
        self.tracks = tracks
        self.scannedAt = scannedAt
    }
}

public protocol LibraryReadProvider: Actor {
    func loadLibrarySnapshot(request: LibraryReadRequest) async throws -> LibraryReadSnapshot
}

public actor MeasuredLibraryProvider: LibraryReadProvider {
    private let base: any LibraryReadProvider
    private let analytics: any AnalyticsService

    public init(base: any LibraryReadProvider, analytics: any AnalyticsService) {
        self.base = base
        self.analytics = analytics
    }

    public func loadLibrarySnapshot(request: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        try await analytics.measure(.musicAppFetch) {
            try await base.loadLibrarySnapshot(request: request)
        }
    }
}
