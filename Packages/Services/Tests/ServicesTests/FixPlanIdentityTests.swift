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
        let producer = FixPlanProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { [musicKitTrack] },
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
                    determineChanges: {
                        try await coordinator.updateTrack(
                            $0,
                            albumTracks: $1,
                            artistTracks: $2,
                            options: $3,
                            dryRun: true
                        )
                    }
                )
            },
            savePlan: { plan, _ in await capture.save(plan) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        ))
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

    private func makeCoordinator(
        mapper: TrackIDMapper,
        bridge: MockAppleScriptClient,
        directory: URL
    ) -> UpdateCoordinator {
        let result = YearResult(year: 2020, confidence: 90, yearScores: [2020: 90])
        let service = MockAPIService(yearResult: result)
        let cache = MockCacheService()
        return UpdateCoordinator(
            dependencies: UpdateCoordinatorDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: service,
                    discogs: service,
                    appleMusic: service,
                    cache: cache
                ),
                scriptBridge: bridge,
                trackStore: MockTrackStore(),
                cache: cache,
                undoCoordinator: UndoCoordinator(scriptBridge: bridge, directory: directory),
                idMapper: mapper
            ),
            genreDeterminator: GenreDeterminator()
        )
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
