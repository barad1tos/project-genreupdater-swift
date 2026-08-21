import Foundation
import Testing
@testable import Core
@testable import Services

extension UpdateCoordinatorTests {
    @Test("Configured album type patterns preserve existing years for uncertain results")
    func preservesSpecialYear() async throws {
        var albumTypeDetection = AlbumTypeDetectionConfig()
        albumTypeDetection.specialPatterns = ["archive"]
        albumTypeDetection.compilationPatterns = []
        albumTypeDetection.reissuePatterns = []

        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(
                missingYearThreshold: 30,
                albumTypeDetection: albumTypeDetection
            )
        )
        let fixture = await makeCoordinator(
            year: 2024,
            confidence: 95,
            runtimeConfiguration: runtimeConfiguration
        )
        await fixture.coordinator.updateRuntimeConfiguration(
            runtimeConfiguration,
            yearDeterminator: YearDeterminator(),
            apiOrchestrator: uncertainYearAPI(year: 2024, confidence: 95)
        )

        let track = makeEditableTrack(album: "Studio Archive", year: 1999)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.isEmpty)
    }

    @Test("Runtime album type configuration update applies to subsequent year updates")
    func updatesAlbumPolicy() async throws {
        let cache = MockCacheService()
        let originalRuntime = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(missingYearThreshold: 30)
        )
        let fixture = await makeCoordinator(
            year: 2024,
            confidence: 95,
            cache: cache,
            runtimeConfiguration: originalRuntime
        )
        await fixture.coordinator.updateRuntimeConfiguration(
            originalRuntime,
            yearDeterminator: YearDeterminator(),
            apiOrchestrator: uncertainYearAPI(year: 2024, confidence: 95)
        )
        let track = makeEditableTrack(album: "Session Archive", year: 1999)

        let beforeUpdate = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        #expect(beforeUpdate.first { $0.changeType == .yearUpdate }?.newValue == "2024")
        await cache.invalidateAlbum(artist: track.artist, album: track.album)

        var albumTypeDetection = AlbumTypeDetectionConfig()
        albumTypeDetection.specialPatterns = ["archive"]
        albumTypeDetection.compilationPatterns = []
        albumTypeDetection.reissuePatterns = []
        await fixture.coordinator.updateRuntimeConfiguration(
            UpdateRuntimeConfiguration(
                policies: UpdateRuntimeConfiguration.Policies(
                    missingYearThreshold: 30,
                    albumTypeDetection: albumTypeDetection
                )
            ),
            yearDeterminator: YearDeterminator()
        )

        let afterUpdate = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )
        #expect(afterUpdate.allSatisfy { $0.changeType != .yearUpdate })
    }

    private func uncertainYearAPI(year: Int, confidence: Int) -> APIOrchestrator {
        let result = YearResult(year: year, confidence: confidence, yearScores: [year: confidence])
        let service = MockAPIService(yearResult: result)
        return makeAPIOrchestrator(
            musicBrainz: service,
            discogs: service,
            appleMusic: service,
            disabledSources: [.discogs, .itunes]
        )
    }

    @Test("Missing-year threshold does not suppress a trusted cache correction")
    func allowsTrustedCacheCorrection() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "Beatles", album: "Abbey Road", year: 1970, confidence: 90)

        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(missingYearThreshold: 95)
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 100,
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        let yearChange = changes.first { $0.changeType == .yearUpdate }
        #expect(yearChange?.newValue == "1970")
        #expect(yearChange?.source == "Cache")
    }

    @Test("Cached year match skips lookup regardless of cache confidence")
    func cachedYearMatchSkipsLookupRegardlessOfCacheConfidence() async throws {
        let cache = MockCacheService()
        await cache.storeAlbumYear(artist: "Beatles", album: "Abbey Road", year: 1969, confidence: 70)

        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(missingYearThreshold: 80)
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 90,
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(!changes.contains { $0.changeType == .yearUpdate })
    }

    @Test("Configured cache threshold skips weak API persistence")
    func configuredCacheThresholdSkipsWeakAPIPersistence() async throws {
        let cache = MockCacheService()
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(
                missingYearThreshold: 30,
                minimumConfidenceToCache: 95
            )
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 30,
            cache: cache,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true, minConfidence: 0),
            dryRun: true
        )

        let yearChange = changes.first { $0.changeType == .yearUpdate }
        #expect(yearChange?.newValue == "2020")

        let cached = await cache.getAlbumYear(artist: "Beatles", album: "Abbey Road")
        #expect(cached == nil)
    }

    @Test("Year lookup setting disables year changes")
    func yearLookupSettingDisablesYearChanges() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(
                isYearLookupEnabled: false,
                missingYearThreshold: 30
            )
        )
        let fixture = await makeCoordinator(
            year: 2020,
            confidence: 95,
            runtimeConfiguration: runtimeConfiguration
        )

        let track = makeEditableTrack(year: 1969)
        let changes = try await fixture.coordinator.updateTrack(
            track,
            options: UpdateOptions(updateGenre: false, updateYear: true),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .yearUpdate })
    }

    @Test("Existing genres are preserved when override is disabled")
    func existingGenresArePreservedWhenOverrideIsDisabled() async throws {
        let fixture = await makeCoordinator()
        let sourceDate = Date(timeIntervalSince1970: 1_234_567_890)
        let track = makeEditableTrack(genre: "Rock")
        let albumTracks = [
            makeEditableTrack(id: "T1", genre: "Electronic", dateAdded: sourceDate),
            makeEditableTrack(id: "T2", genre: "Electronic", dateAdded: sourceDate.addingTimeInterval(60)),
        ]

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        #expect(changes.allSatisfy { $0.changeType != .genreUpdate })
    }

    @Test("Existing genres update when override is enabled")
    func existingGenresUpdateWhenOverrideIsEnabled() async throws {
        let runtimeConfiguration = UpdateRuntimeConfiguration(
            policies: UpdateRuntimeConfiguration.Policies(shouldOverrideExistingGenres: true)
        )
        let fixture = await makeCoordinator(runtimeConfiguration: runtimeConfiguration)
        let sourceDate = Date(timeIntervalSince1970: 1_234_567_890)
        let track = makeEditableTrack(genre: "Rock")
        let albumTracks = [
            makeEditableTrack(id: "T1", genre: "Electronic", dateAdded: sourceDate),
            makeEditableTrack(id: "T2", genre: "Electronic", dateAdded: sourceDate.addingTimeInterval(60)),
        ]

        let changes = try await fixture.coordinator.updateTrack(
            track,
            albumTracks: albumTracks,
            options: UpdateOptions(updateGenre: true, updateYear: false),
            dryRun: true
        )

        let genreChange = changes.first { $0.changeType == .genreUpdate }
        #expect(genreChange?.oldValue == "Rock")
        #expect(genreChange?.newValue == "Electronic")
    }
}
