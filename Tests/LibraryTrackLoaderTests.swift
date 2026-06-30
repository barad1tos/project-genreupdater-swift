import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("LibraryTrackLoader")
@MainActor
struct LibraryTrackLoaderTests {
    @Test("Live provider load marks library ready without mutation metadata preload")
    func liveProviderLoadMarksLibraryReadyWithoutMutationMetadataPreload() async throws {
        let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = LoaderReadProvider(
            snapshot: LibraryReadSnapshot(
                tracks: [
                    Track(id: "MK-1", name: "Battery", artist: "Metallica", album: "Master of Puppets"),
                ],
                scannedAt: scannedAt
            )
        )

        let load = try await LibraryTrackLoader.liveTracks(
            provider: provider,
            scopedArtists: [" Metallica "]
        )

        #expect(load.tracks.map(\.id) == ["MK-1"])
        #expect(load.isLibraryReadyForUpdates)
        #expect(load.scanDate == scannedAt)
        #expect(await provider.requests.map(\.testArtists) == [["Metallica"]])
    }
}

private actor LoaderReadProvider: LibraryReadProvider {
    var requests: [LibraryReadRequest] = []
    private let snapshot: LibraryReadSnapshot

    init(snapshot: LibraryReadSnapshot) {
        self.snapshot = snapshot
    }

    func loadLibrarySnapshot(request: LibraryReadRequest) async throws -> LibraryReadSnapshot {
        requests.append(request)
        return snapshot
    }
}
