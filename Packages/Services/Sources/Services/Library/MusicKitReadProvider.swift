import Core
import Foundation

protocol MusicLibrarySnapshotReader: Actor {
    func fetchAllTracks(
        artist: String?,
        testArtists: [String],
        ignoreTestFilter: Bool
    ) async throws -> [Track]
}

extension MusicLibraryReader: MusicLibrarySnapshotReader {}

public actor MusicKitReadProvider: LibraryReadProvider {
    private let snapshotReader: any MusicLibrarySnapshotReader
    private let currentDate: @Sendable () -> Date

    public init(
        reader: MusicLibraryReader,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        snapshotReader = reader
        self.currentDate = currentDate
    }

    init(
        snapshotReader: any MusicLibrarySnapshotReader,
        currentDate: @escaping @Sendable () -> Date
    ) {
        self.snapshotReader = snapshotReader
        self.currentDate = currentDate
    }

    public func loadLibrarySnapshot(request: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        try Task.checkCancellation()
        let tracks = try await snapshotReader.fetchAllTracks(
            artist: nil,
            testArtists: request.testArtists,
            ignoreTestFilter: false
        )
        return LibraryReadSnapshot(tracks: tracks, scannedAt: currentDate())
    }
}
