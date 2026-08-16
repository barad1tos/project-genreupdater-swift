import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - genre repair")
struct GenreRepairTests {
    @Test(
        "Unavailable tracks remain genre evidence for an editable target",
        arguments: [TrackKind.prerelease, TrackKind.noLongerAvailable]
    )
    func readOnlyEvidence(kind: TrackKind) async throws {
        let fixture = await makeCoordinator()
        let evidenceTrack = Track(
            id: "evidence",
            name: "Evidence Song",
            artist: "Artist",
            album: "Earlier Album",
            genre: "Post-Punk",
            dateAdded: Date(timeIntervalSince1970: 100),
            trackStatus: kind.rawValue
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Target Song",
            artist: "Artist",
            album: "Later Album",
            genre: "Alternative",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let changes = try await fixture.coordinator.updateTrack(
            targetTrack,
            artistTracks: [evidenceTrack, targetTrack],
            options: UpdateOptions(
                updateGenre: true,
                updateYear: false,
                repairExistingGenreMismatches: true
            ),
            dryRun: true
        )

        let genreChange = try #require(changes.first { $0.changeType == .genreUpdate })
        #expect(genreChange.track.id == "target")
        #expect(genreChange.newValue == "Post-Punk")
    }

    @Test(
        "Generated writes retain unavailable genre evidence",
        arguments: [TrackKind.prerelease, TrackKind.noLongerAvailable]
    )
    func evidenceWrite(kind: TrackKind) async throws {
        let fixture = await makeCoordinator()
        let evidenceTrack = Track(
            id: "evidence",
            name: "Evidence Song",
            artist: "Artist",
            album: "Earlier Album",
            genre: "Post-Punk",
            dateAdded: Date(timeIntervalSince1970: 100),
            trackStatus: kind.rawValue
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Target Song",
            artist: "Artist",
            album: "Later Album",
            genre: nil,
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let result = try await fixture.coordinator.updateTracks(
            [evidenceTrack, targetTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false),
            progressHandler: ignoreProgress
        )

        #expect(result.entries.map(\.trackID) == ["target"])
        #expect(await fixture.bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "target", property: "genre", value: "Post-Punk"),
        ])
    }

    @Test("Feature credits share genre evidence on the generated write path")
    func featureCreditWrite() async throws {
        let fixture = await makeCoordinator()
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "Earlier Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Target Song",
            artist: "Artist feat. Guest",
            album: "Later Album",
            genre: nil,
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let result = try await fixture.coordinator.updateTracks(
            [sourceTrack, targetTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false),
            progressHandler: ignoreProgress
        )

        #expect(result.entries.map(\.trackID) == ["target"])
        #expect(await fixture.bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "target", property: "genre", value: "Post-Punk"),
        ])
    }

    @Test("Year confidence does not suppress a generated genre write")
    func preservesGenreWrite() async throws {
        let fixture = await makeCoordinator()
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "Earlier Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Target Song",
            artist: "Artist",
            album: "Later Album",
            genre: nil,
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let changes = try await fixture.coordinator.updateTrack(
            targetTrack,
            artistTracks: [sourceTrack, targetTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false, minConfidence: 100),
            dryRun: false
        )

        #expect(changes.map(\.changeType) == [.genreUpdate])
        #expect(await fixture.bridge.writtenProperties == [
            TrackPropertyUpdate(trackID: "target", property: "genre", value: "Post-Punk"),
        ])
    }

    @Test("Missing target write identity blocks an inferred genre write")
    func missingTargetIdentity() async {
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "Earlier Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Target Song",
            artist: "Artist feat. Guest",
            album: "Later Album",
            genre: nil,
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )
        let fixture = await makeCoordinator(
            idMapper: GenreIdentityMapper(mappedTrack: sourceTrack)
        )

        do {
            _ = try await fixture.coordinator.updateTracks(
                [sourceTrack, targetTrack],
                options: UpdateOptions(updateGenre: true, updateYear: false),
                progressHandler: ignoreProgress
            )
            Issue.record("Expected the missing target identity to block the write")
        } catch let error as UpdateCoordinatorError {
            guard case let .allTracksFailed(count, descriptions) = error else {
                Issue.record("Expected allTracksFailed, got \(error)")
                return
            }
            #expect(count == 1)
            #expect(descriptions.contains { $0.contains("target") })
        } catch {
            Issue.record("Expected UpdateCoordinatorError, got \(error)")
        }
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("Unknown genre is repaired like missing genre")
    func unknownGenreIsRepairedLikeMissingGenre() async throws {
        let fixture = await makeCoordinator()
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "First Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Unknown Genre Song",
            artist: "Artist",
            album: "Later Album",
            genre: "Unknown",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let changes = try await fixture.coordinator.updateTrack(
            targetTrack,
            artistTracks: [sourceTrack, targetTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = try #require(changes.first { $0.changeType == .genreUpdate })
        #expect(genreChange.oldValue == "Unknown")
        #expect(genreChange.newValue == "Post-Punk")
    }

    @Test("Unknown genre is not used as repair source")
    func unknownGenreIsNotUsedAsRepairSource() async throws {
        let fixture = await makeCoordinator()
        let targetTrack = makeEditableTrack(
            id: "target",
            name: "Unknown Genre Song",
            artist: "Artist",
            album: "First Album",
            genre: "Unknown",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 100)
        )
        let sourceTrack = makeEditableTrack(
            id: "source",
            name: "Source Song",
            artist: "Artist",
            album: "Later Album",
            genre: "Post-Punk",
            year: nil,
            dateAdded: Date(timeIntervalSince1970: 200)
        )

        let changes = try await fixture.coordinator.updateTrack(
            targetTrack,
            artistTracks: [targetTrack, sourceTrack],
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = try #require(changes.first { $0.changeType == .genreUpdate })
        #expect(genreChange.newValue == "Post-Punk")
    }

    private func makeCoordinator(
        idMapper: (any TrackIDMapping)? = nil
    ) async -> GenreRepairFixture {
        let bridge = MockAppleScriptClient()
        let apiService = MockAPIService()
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: apiService,
            discogs: apiService,
            appleMusic: apiService
        )
        let undoDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenreRepairTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(scriptBridge: bridge, directory: undoDirectory)

        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: orchestrator,
                scriptBridge: bridge,
                stores: .init(
                    trackStore: MockTrackStore(),
                    cache: MockCacheService()
                ),
                undoCoordinator: undo,
                idMapper: idMapper
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator()
        )
        return GenreRepairFixture(
            coordinator: coordinator,
            bridge: bridge
        )
    }
}

private struct GenreRepairFixture {
    let coordinator: UpdateCoordinator
    let bridge: MockAppleScriptClient
}

private actor GenreIdentityMapper: TrackIDMapping {
    private let mappedTrack: Track

    init(mappedTrack: Track) {
        self.mappedTrack = mappedTrack
    }

    func appleScriptID(forMusicKitID musicKitID: String) async -> String? {
        musicKitID == mappedTrack.id ? "AS-source" : nil
    }

    func trackWithAppleScriptMetadata(for musicKitTrack: Track) async -> Track? {
        guard musicKitTrack.id == mappedTrack.id else { return nil }
        var enrichedTrack = mappedTrack
        enrichedTrack.appleScriptID = "AS-source"
        enrichedTrack.trackStatus = TrackKind.subscription.rawValue
        return enrichedTrack
    }

    func refreshMapping(musicKitTracks: [Track], appleScriptTracks: [Track]) async {
        _ = musicKitTracks
        _ = appleScriptTracks
    }

    func hasMappingFor(musicKitID: String) async -> Bool {
        musicKitID == mappedTrack.id
    }
}

private func ignoreProgress(_ update: ProgressUpdate) {
    _ = update
}
