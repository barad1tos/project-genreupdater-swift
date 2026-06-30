import Core
import Foundation

public struct LibraryReadRequest: Sendable, Equatable {
    public let testArtists: [String]

    public init(
        testArtists: [String] = []
    ) {
        self.testArtists = ArtistAllowList.normalized(testArtists)
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
