import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview plan producer")
@MainActor
struct PreviewPlanTests {
    private typealias Producer = @Sendable (
        RunID,
        ProcessingScopeSnapshot,
        FixPlanConfig
    ) async throws -> FixPlanProduction

    @Test("uses supplied options and saves a plan")
    func savesPlan() async throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 73
        let dependencies = AppDependencies(
            configurationLoader: { configuration },
            configurationSaver: { _ in
                // This test only verifies preview option resolution, not config persistence.
            }
        )
        let probe = PreviewProducerProbe()
        let planConfiguration = FixPlanConfig.capture(
            configuration: configuration,
            options: PreviewRunOptions.make(
                configuration: configuration,
                updateGenre: false,
                updateYear: true
            ),
            capturedAt: Date(timeIntervalSince1970: 50)
        )
        let runID = RunID()
        let requestedScope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["Probe Artist"],
            knownTrackCount: 1,
            createdAt: probe.producedAt,
            reason: "previewProducerTest"
        )
        let admission = workflowProcessingAdmission(scope: requestedScope)
        let scope = requestedScope.certified(by: admission)
        let producer = makeProducer(dependencies: dependencies, probe: probe, admission: admission)

        let production = try await producer(runID, scope, planConfiguration)
        let snapshot = await probe.snapshot()

        #expect(production.proposalCount == 1)
        #expect(production.planID == snapshot.savedPlan?.id)
        #expect(snapshot.loadedCount == 1)
        #expect(snapshot.refreshInputIDs == ["track-1"])
        #expect(snapshot.refreshScope == scope)
        #expect(snapshot.albumContextInputIDs == ["track-1"])
        #expect(snapshot.determinedTrackID == "track-1")
        #expect(snapshot.determinedAlbumIDs == ["album-peer"])
        #expect(snapshot.determinedArtistIDs == ["track-1"])
        #expect(snapshot.options?.updateGenre == false)
        #expect(snapshot.options?.updateYear == true)
        #expect(snapshot.options?.minConfidence == 73)
        #expect(snapshot.savedPlan?.sourceRunID == runID)
        #expect(snapshot.savedPlan?.configuration.id == planConfiguration.id)
        #expect(snapshot.savedPlan?.configuration.updateGenre == false)
        #expect(snapshot.savedPlan?.configuration.updateYear == true)
        #expect(snapshot.savedPlan?.configuration.minConfidence == 73)
        #expect(snapshot.savedDecision?.planID == snapshot.savedPlan?.id)
        #expect(snapshot.savedDecision?.planRevision == snapshot.savedPlan?.revision)
    }

    private func makeProducer(
        dependencies: AppDependencies,
        probe: PreviewProducerProbe,
        admission: ProcessingAdmission
    ) -> Producer {
        dependencies.makePreviewProducer(dependencies: FixPlanProducer.Dependencies(
            loadAdmission: { _, _ in
                await .admitted(
                    admission,
                    tracks: probe.loadTracks()
                )
            },
            makeRuntime: { _, _ in
                FixPlanProducer.Runtime(
                    refreshIdentity: { await probe.refreshWriteIdentity(for: $0, scope: $1) },
                    albumContext: { await probe.albumContextTracksByTrackID(for: $0) },
                    artistContext: Self.singleTrackArtistContext,
                    determineChanges: { track, albumTracks, artistTracks, options, _ in
                        try await probe.determineTrackChanges(
                            track: track,
                            albumTracks: albumTracks,
                            artistTracks: artistTracks,
                            options: options
                        )
                    }
                )
            },
            savePlan: { await probe.savePlan($0, initialDecision: $1) },
            now: { probe.producedAt }
        ))
    }

    private static func singleTrackArtistContext(_ tracks: [Track]) -> [String: [Track]] {
        Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, [$0]) })
    }

    @Test("write identity refresh forwards test artist scope")
    func refreshesTestArtistScope() async throws {
        let mapper = TrackIDMapper()
        let script = PreviewScriptClient(tracks: [appleScriptTrack(id: "AS-TRACK")])
        let refresher = WriteIdentityRefresher(mapper: mapper, source: script)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: ["probe artist"],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )

        try await refresher.refresh(
            tracks: [musicKitTrack(id: "MK-TRACK")],
            scope: scope
        )

        #expect(await script.identityScopes() == [["probe artist"]])
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-TRACK") == "AS-TRACK")
    }

    @Test("full library refresh preserves existing mappings")
    func refreshesFullLibrary() async throws {
        let mapper = TrackIDMapper()
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack(id: "MK-OLD", name: "Old")],
            appleScriptTracks: [appleScriptTrack(id: "AS-OLD", name: "Old")]
        )
        let script = PreviewScriptClient(tracks: [appleScriptTrack(id: "AS-NEW", name: "New")])
        let refresher = WriteIdentityRefresher(mapper: mapper, source: script)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )

        try await refresher.refresh(
            tracks: [musicKitTrack(id: "MK-NEW", name: "New")],
            scope: scope
        )

        #expect(await script.identityScopes() == [[]])
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-OLD") == "AS-OLD")
        #expect(await mapper.appleScriptID(forMusicKitID: "MK-NEW") == "AS-NEW")
    }
}
