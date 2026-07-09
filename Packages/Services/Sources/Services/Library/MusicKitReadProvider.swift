import Core
import Foundation

public actor MusicKitReadProvider: LibraryReadProvider {
    private let reader: MusicLibraryReader
    private let currentDate: @Sendable () -> Date

    public init(
        reader: MusicLibraryReader,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.currentDate = currentDate
    }

    public func loadLibrarySnapshot(request: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        try await reader.requestAuthorization()
        try Task.checkCancellation()
        await reader.updateTestArtists(request.testArtists)
        let tracks = try await reader.fetchAllTracks()
        return LibraryReadSnapshot(tracks: tracks, scannedAt: currentDate())
    }
}
