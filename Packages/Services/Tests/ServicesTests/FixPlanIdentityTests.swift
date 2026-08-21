import Core
import Foundation
import Services
import Testing

@Suite("Fix plan identity")
struct FixPlanIdentityTests {
    @Test("refreshed write identity reaches the saved plan")
    func savesRefreshedIdentity() async throws {
        let musicKitTrack = makeEditableTrack(id: "MK-1")
        let appleScriptTrack = Track(
            id: "AS-1",
            name: musicKitTrack.name,
            artist: musicKitTrack.artist,
            album: musicKitTrack.album,
            genre: musicKitTrack.genre,
            year: musicKitTrack.year,
            trackStatus: musicKitTrack.trackStatus,
            appleScriptID: "AS-1"
        )
        let mapper = TrackIDMapper()
        let bridge = MockAppleScriptClient()
        await bridge.setFetchedTracks([appleScriptTrack])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixPlanIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(mapper: mapper, bridge: bridge, directory: directory)
        let capture = PlanCapture()
        let producer = makeProducer(
            track: musicKitTrack,
            mapper: mapper,
            bridge: bridge,
            coordinator: coordinator,
            capture: capture
        )
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(updateGenre: false, updateYear: true),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        _ = try await producer.producePlan(
            sourceRunID: RunID(),
            scope: scope,
            configuration: configuration
        )

        let plan = try #require(await capture.plan())
        #expect(plan.items.first?.identity.appleScriptID == "AS-1")
    }

    @Test("Plan production shares one year decision scope")
    func sharesYearScope() async throws {
        let fixture = makeScopeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(
                updateGenre: false,
                updateYear: true,
                forceYearLookup: true,
                minConfidence: 0
            ),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let production = try await fixture.producer.producePlan(
            sourceRunID: RunID(),
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: [],
                knownTrackCount: fixture.tracks.count,
                createdAt: Date(timeIntervalSince1970: 100),
                reason: "test"
            ),
            configuration: configuration
        )

        let plan = try #require(await fixture.capture.plan())
        #expect(production.proposalCount == 2)
        #expect(plan.items.map(\.identity.readID) == ["T1", "T2"])
        #expect(plan.items.map(\.newValue) == ["2020", "2020"])
        #expect(await fixture.scopeProbe.uniqueCount == 1)
        #expect(await fixture.apiProbe.requestCount == 2)
    }

    private func makeScopeFixture() -> YearScopeFixture {
        let tracks = makeScopeTracks()
        let apiProbe = APIRequestProbe()
        let apiService = UpdateAPIDouble(
            probe: apiProbe,
            yearResult: YearResult(
                year: 2020,
                isDefinitive: true,
                confidence: 100,
                yearScores: [2020: 100]
            )
        )
        let bridge = MockAppleScriptClient()
        let cache = MockCacheService()
        let scopeProbe = YearScopeProbe()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixPlanYearScope-\(UUID().uuidString)")
        let coordinator = makeScopeCoordinator(
            apiService: apiService,
            bridge: bridge,
            cache: cache,
            directory: directory
        )
        let capture = PlanCapture()
        return YearScopeFixture(
            tracks: tracks,
            producer: makeScopeProducer(
                tracks: tracks,
                coordinator: coordinator,
                capture: capture,
                scopeProbe: scopeProbe
            ),
            capture: capture,
            apiProbe: apiProbe,
            scopeProbe: scopeProbe,
            directory: directory
        )
    }

    private func makeScopeTracks() -> [Track] {
        [
            Track(
                id: "T1",
                name: "First",
                artist: "Artist",
                album: "Album",
                year: 1969,
                trackStatus: nil
            ),
            Track(
                id: "T2",
                name: "Second",
                artist: "Artist",
                album: "Album",
                year: 1969,
                trackStatus: nil
            ),
        ]
    }

    private func makeScopeCoordinator(
        apiService: UpdateAPIDouble,
        bridge: MockAppleScriptClient,
        cache: MockCacheService,
        directory: URL
    ) -> UpdateCoordinator {
        UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService,
                    cache: cache,
                    disabledSources: [.discogs, .itunes]
                ),
                scriptBridge: bridge,
                stores: .init(trackStore: MockTrackStore(), cache: cache),
                undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: directory)
            ),
            genreDeterminator: GenreDeterminator()
        )
    }

    private func makeScopeProducer(
        tracks: [Track],
        coordinator: UpdateCoordinator,
        capture: PlanCapture,
        scopeProbe: YearScopeProbe
    ) -> FixPlanProducer {
        FixPlanProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { tracks },
            makeRuntime: { _, _ in
                FixPlanProducer.Runtime(
                    refreshIdentity: { tracks, _ in #expect(tracks.count == 2) },
                    albumContext: {
                        await coordinator.albumContextTracksByTrackID(for: $0, requiresMutationMetadata: false)
                    },
                    artistContext: {
                        await coordinator.artistContextTracksByTrackID(for: $0)
                    },
                    determineChanges: {
                        await scopeProbe.record($4)
                        return try await coordinator.updateTrack(
                            $0,
                            albumTracks: $1,
                            artistTracks: $2,
                            options: $3,
                            dryRun: true,
                            yearRunScope: $4
                        )
                    }
                )
            },
            savePlan: { plan, _ in await capture.save(plan) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ))
    }

    private func makeProducer(
        track: Track,
        mapper: TrackIDMapper,
        bridge: MockAppleScriptClient,
        coordinator: UpdateCoordinator,
        capture: PlanCapture
    ) -> FixPlanProducer {
        FixPlanProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { [track] },
            makeRuntime: { _, _ in
                FixPlanProducer.Runtime(
                    refreshIdentity: { tracks, _ in
                        _ = try await mapper.refreshMapping(
                            musicKitTracks: tracks,
                            appleScriptClient: bridge,
                            batchSize: 50,
                            allTrackIDsTimeout: .seconds(5),
                            tracksByIDsTimeout: .seconds(5),
                            mergeExisting: true
                        )
                    },
                    albumContext: {
                        await coordinator.albumContextTracksByTrackID(for: $0, requiresMutationMetadata: false)
                    },
                    artistContext: {
                        await coordinator.artistContextTracksByTrackID(for: $0)
                    },
                    determineChanges: {
                        try await coordinator.updateTrack(
                            $0,
                            albumTracks: $1,
                            artistTracks: $2,
                            options: $3,
                            dryRun: true,
                            yearRunScope: $4
                        )
                    }
                )
            },
            savePlan: { plan, _ in await capture.save(plan) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ))
    }

    private func makeCoordinator(
        mapper: TrackIDMapper,
        bridge: MockAppleScriptClient,
        directory: URL
    ) -> UpdateCoordinator {
        let result = YearResult(year: 2020, confidence: 90, yearScores: [2020: 90])
        let service = MockAPIService(yearResult: result)
        let cache = MockCacheService()
        return UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: service,
                    discogs: service,
                    appleMusic: service,
                    cache: cache
                ),
                scriptBridge: bridge,
                stores: .init(trackStore: MockTrackStore(), cache: cache),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: directory
                ),
                idMapper: mapper
            ),
            genreDeterminator: GenreDeterminator()
        )
    }
}

private struct YearScopeFixture {
    let tracks: [Track]
    let producer: FixPlanProducer
    let capture: PlanCapture
    let apiProbe: APIRequestProbe
    let scopeProbe: YearScopeProbe
    let directory: URL
}

private actor YearScopeProbe {
    private var scopes: [YearRunScope] = []

    var uniqueCount: Int {
        Set(scopes.map(ObjectIdentifier.init)).count
    }

    func record(_ scope: YearRunScope) {
        scopes.append(scope)
    }
}

private actor PlanCapture {
    private var savedPlan: FixPlan?

    func save(_ plan: FixPlan) {
        savedPlan = plan
    }

    func plan() -> FixPlan? {
        savedPlan
    }
}
