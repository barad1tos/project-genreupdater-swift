import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("AppDependencies library services")
@MainActor
struct AppDependenciesLibraryServicesTests {
    @Test("Scoped test-artist load skips full-library snapshot")
    func scopedTestArtistLoadSkipsFullLibrarySnapshot() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("Scoped test-artist load still persists track state")
    func scopedTestArtistLoadStillPersistsTrackState() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        let storedTracks = try await fixture.trackStore.loadAllTracks()
        #expect(storedTracks.map(\.id) == ["track-1"])
    }

    @Test("Full-library load saves snapshot")
    func fullLibraryLoadSavesSnapshot() async throws {
        let fixture = try makeFixture(testArtists: [])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
        #expect(await fixture.snapshotService.savedTrackIDs() == ["track-1"])
    }

    @Test("Blank-only test artists save full-library snapshot")
    func blankOnlyTestArtistsSaveFullLibrarySnapshot() async throws {
        let fixture = try makeFixture(testArtists: ["  "])
        let tracks = [sampleTrack()]

        await fixture.dependencies.persistLoadedLibraryTracks(tracks)

        #expect(await fixture.snapshotService.savedSnapshotCount() == 1)
    }

    @Test("Captured scoped load skips snapshot after config becomes full-library")
    func capturedScopedLoadSkipsSnapshotAfterConfigBecomesFullLibrary() async throws {
        let fixture = try makeFixture(testArtists: ["Clutch"])
        let capturedScope = ArtistAllowList.normalized(fixture.dependencies.config.development.testArtists)
        fixture.dependencies.config.development.testArtists = []

        await fixture.dependencies.persistLoadedLibraryTracks(
            [sampleTrack()],
            scopedArtists: capturedScope
        )

        #expect(await fixture.snapshotService.savedSnapshotCount() == 0)
    }

    @Test("MainView load persistence passes captured scope")
    func mainViewLoadPersistencePassesCapturedScope() throws {
        let source = try String(contentsOf: mainViewDataSourceURL(), encoding: .utf8)
        let compactSource = source.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        #expect(
            compactSource.contains(
                "await dependencies.persistLoadedLibraryTracks(liveTracks, scopedArtists: scopedArtists)"
            )
        )
    }

    @Test("Reports backup import propagates mapping refresh errors")
    func reportsBackupImportPropagatesMappingRefreshErrors() throws {
        let source = try String(contentsOf: reportsViewSourceURL(), encoding: .utf8)
        let compactSource = source.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        #expect(
            compactSource.contains(
                [
                    "let mappedTrackCount = try await dependencies.refreshTrackIDMappingOrThrow(",
                    "musicKitTracks: tracks,",
                    "scopedArtists: [artist],",
                    "mergeExisting: true",
                    ")",
                ].joined(separator: " ")
            )
        )
        #expect(
            compactSource.contains(
                [
                    "guard mappedTrackCount > 0 || tracks.isEmpty else {",
                    "throw BackupCSVImportError.noWritableTrackMapping",
                    "}",
                ].joined(separator: " ")
            )
        )
    }
}

private struct LibraryPersistenceFixture {
    let dependencies: AppDependencies
    let trackStore: SwiftDataTrackStore
    let snapshotService: SnapshotServiceSpy
}

@MainActor
private func makeFixture(testArtists: [String]) throws -> LibraryPersistenceFixture {
    let trackStore = try SwiftDataTrackStore.createInMemory()
    let snapshotService = SnapshotServiceSpy()
    let dependencies = AppDependencies(
        configurationLoader: {
            var configuration = AppConfiguration()
            configuration.development.testArtists = testArtists
            return configuration
        },
        configurationSaver: { _ in
            // Tests keep configuration in memory.
        }
    )
    dependencies.configureLibraryPersistenceForTesting(
        trackStore: trackStore,
        librarySnapshotService: snapshotService
    )
    return LibraryPersistenceFixture(
        dependencies: dependencies,
        trackStore: trackStore,
        snapshotService: snapshotService
    )
}

private func sampleTrack() -> Track {
    Track(
        id: "track-1",
        name: "Electric Worry",
        artist: "Clutch",
        album: "From Beale Street to Oblivion",
        genre: "Rock",
        year: 2007,
        trackStatus: "purchased"
    )
}

private func mainViewDataSourceURL() throws -> URL {
    var currentURL = URL(fileURLWithPath: #filePath)
    currentURL.deleteLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = currentURL.appendingPathComponent("App/Views/MainView+Data.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        currentURL.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

private func reportsViewSourceURL() throws -> URL {
    var currentURL = URL(fileURLWithPath: #filePath)
    currentURL.deleteLastPathComponent()

    for _ in 0 ..< 8 {
        let candidate = currentURL.appendingPathComponent("App/Views/ReportsView.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        currentURL.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
}

private actor SnapshotServiceSpy: LibrarySnapshotService {
    var isEnabled = true
    var isDeltaEnabled = true
    private var saveSnapshotCallCount = 0
    private var savedTracks: [Track] = []

    func loadSnapshot() async throws -> [Track]? {
        nil
    }

    func saveSnapshot(_ tracks: [Track]) async throws -> String {
        saveSnapshotCallCount += 1
        savedTracks = tracks
        return "snapshot"
    }

    func clearSnapshot() async {
        // Snapshot clearing is outside this spy's assertions.
    }

    func isSnapshotValid() async -> Bool {
        true
    }

    func getSnapshotMetadata() async -> LibraryCacheMetadata? {
        nil
    }

    func updateSnapshotMetadata(_: LibraryCacheMetadata) async throws {
        // Metadata writes are outside this spy's assertions.
    }

    func loadDelta() async -> LibraryDeltaCache? {
        nil
    }

    func saveDelta(_: LibraryDeltaCache) async throws {
        // Delta writes are outside this spy's assertions.
    }

    func getLibraryModificationDate() async throws -> Date {
        .distantPast
    }

    func savedSnapshotCount() -> Int {
        saveSnapshotCallCount
    }

    func savedTrackIDs() -> [String] {
        savedTracks.map(\.id)
    }
}
