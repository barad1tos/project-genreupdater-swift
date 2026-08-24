import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("LibraryReadProvider")
struct LibraryReadProviderTests {
    @Test("Snapshot preserves tracks and scan date")
    func snapshotPreservesTracksAndScanDate() {
        let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tracks = [
            Track(id: "MK-1", name: "Battery", artist: "Metallica", album: "Master of Puppets")
        ]

        let snapshot = LibraryReadSnapshot(tracks: tracks, scannedAt: scannedAt)

        #expect(snapshot.tracks.map(\.id) == ["MK-1"])
        #expect(snapshot.scannedAt == scannedAt)
    }

    @Test("Request normalizes test artists")
    func requestNormalizesTestArtists() {
        let request = LibraryReadRequest(testArtists: [" Metallica ", "", "Radiohead"])

        #expect(request.testArtists == ["Metallica", "Radiohead"])
    }

    @Test("Concurrent snapshots retain their own artist scopes")
    func retainsConcurrentScopes() async throws {
        let reader = ScopedSnapshotReader(tracks: [
            Track(id: "1", name: "Jóga", artist: "Björk", album: "Homogenic"),
            Track(id: "2", name: "Cloud Connected", artist: "In Flames", album: "Reroute to Remain"),
        ])
        let provider = MusicKitReadProvider(
            snapshotReader: reader,
            currentDate: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        async let fullSnapshot = provider.loadLibrarySnapshot(request: LibraryReadRequest())
        async let scopedSnapshot = provider.loadLibrarySnapshot(request: LibraryReadRequest(testArtists: ["Björk"]))
        let (full, scoped) = try await (fullSnapshot, scopedSnapshot)

        #expect(Set(full.tracks.map(\.id)) == ["1", "2"])
        #expect(scoped.tracks.map(\.id) == ["1"])
        #expect(await reader.receivedScopes() == [[], ["Björk"]])
    }
}

private actor ScopedSnapshotReader: MusicLibrarySnapshotReader {
    private let tracks: [Track]
    private var scopes: [[String]] = []
    private var firstArrival: CheckedContinuation<Void, Never>?

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    func fetchAllTracks(
        artist _: String?,
        testArtists: [String],
        ignoreTestFilter _: Bool
    ) async throws -> [Track] {
        scopes.append(testArtists)
        if let firstArrival {
            self.firstArrival = nil
            firstArrival.resume()
        } else {
            await withCheckedContinuation { continuation in
                firstArrival = continuation
            }
        }

        return MusicLibraryReader.filterByTestArtists(tracks, testArtists: testArtists)
    }

    func receivedScopes() -> [[String]] {
        scopes.sorted { $0.count < $1.count }
    }
}
