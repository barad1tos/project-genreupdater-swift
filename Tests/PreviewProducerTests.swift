import Core
import Foundation
import Testing
@testable import Genre_Updater
@testable import Services

@Suite("Preview producer runtime")
@MainActor
struct PreviewProducerTests {
    @Test("production preview admits post-sync mirror rows without loading all tracks")
    func usesMirrorAdmission() async throws {
        let observedAt = Date()
        let admittedTrack = Track(
            id: "admitted-track",
            name: "Admitted Song",
            artist: "Probe Artist",
            album: "Admitted Album",
            appleScriptID: "admitted-track"
        )
        let store = try PreviewAdmissionStore(
            track: admittedTrack,
            testArtists: ["Probe Artist"],
            observedAt: observedAt
        )
        var appConfiguration = AppConfiguration()
        appConfiguration.development.testArtists = ["Probe Artist"]
        let configuration = FixPlanConfig.capture(
            configuration: appConfiguration,
            options: UpdateOptions(updateGenre: false, updateYear: false),
            capturedAt: observedAt
        )
        let runScope = scope(artist: "Probe Artist")
        let services = RunServiceFactory(
            makeMusicAccess: { _ in previewAccess(PreviewScriptClient(tracks: [admittedTrack])) },
            makePendingVerification: { _ in nil }
        )
        let runtime = try await makeRuntime(services: services)
        _ = try await runtime.makeSync(configuration: configuration, scope: runScope)
        let dependencies = AppDependencies(
            configurationLoader: { appConfiguration },
            modelContainerFactory: ModelContainerFactory.createInMemory
        )
        dependencies.configureLibraryPersistenceForTesting(
            trackStore: store,
            fixPlanStore: StoredFixPlanStore(plan: nil, decision: nil)
        )
        let producer = try #require(dependencies.makePreviewProducer(runtime: runtime))

        let production = try await producer(RunID(), runScope, configuration)

        #expect(production == .empty)
        #expect(await store.mirrorLoadCount() == 1)
        #expect(await store.allTrackLoadTotal() == 0)
    }

    @Test("album-targeted sync certifies the submitted scope for production preview")
    func certifiesAlbumPreview() async throws {
        let fixture = try await makeAlbumPreviewFixture()
        let sync = try await fixture.runtime.makeSync(
            configuration: fixture.configuration,
            scope: fixture.scope
        )
        _ = try await sync.synchronizeNow(forceMetadataRefresh: true)
        let producer = try #require(fixture.dependencies.makePreviewProducer(runtime: fixture.runtime))
        let production = try await producer(RunID(), fixture.scope, fixture.configuration)
        let snapshot = try await fixture.store.loadMirrorSnapshot()
        let requirement = try LibrarySyncRuntimeConfiguration(
            configuration: fixture.appConfiguration
        ).processingRequirement
        #expect(snapshot.readiness(for: requirement, at: Date()).isReady)
        #expect(production.proposalCount == 1)
        let planID = try #require(production.planID)
        let plan = try #require(await fixture.planStore.plan(id: planID, revision: .initial))
        guard case let .certified(admission) = plan.admission else {
            Issue.record("Production preview must persist certified admission")
            return
        }
        #expect(admission.scopeID == fixture.scope.id)
        #expect(Set(admission.certificate.normalizedTestArtists) == Set(fixture.scope.normalizedTestArtists))
        #expect(plan.items.map(\.identity.readID) == [fixture.target.id])
    }

    @Test("Invalid historical configuration blocks sync before runtime services")
    func rejectsInvalidSync() async throws {
        try await expectRuntimeRejection(at: .sync)
    }

    @Test("Invalid historical configuration blocks preview before runtime services")
    func rejectsInvalidPreview() async throws {
        try await expectRuntimeRejection(at: .preview)
    }

    @Test("Invalid historical configuration blocks write before runtime services")
    func rejectsInvalidWrite() async throws {
        try await expectRuntimeRejection(at: .write)
    }

    @Test("Recovered rate-limit overflow fails before runtime services")
    func rejectsRateOverflow() async throws {
        try await expectRuntimeRejection(at: .preview) {
            $0.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 1e-308
        }
    }

    @Test("Recovered batch-delay overflow fails before runtime services")
    func rejectsDelayOverflow() async throws {
        try await expectRuntimeRejection(at: .preview) {
            $0.processing.delayBetweenBatches = 1e308
        }
    }

    @Test("Conflicting artist mappings block every runtime entry point")
    func rejectsArtistConflicts() async throws {
        for entryPoint in RuntimeEntryPoint.allCases {
            try await expectRuntimeRejection(at: entryPoint) {
                $0.artistRenamer.mappings = [
                    " oldartist  ": "Second",
                    "OldArtist": "First",
                ]
            }
        }
    }

    private func expectRuntimeRejection(
        at entryPoint: RuntimeEntryPoint,
        mutate: (inout AppConfiguration) -> Void = { $0.genreUpdate.batchSize = 0 }
    ) async throws {
        let services = RunServiceFactory(
            makeMusicAccess: { _ in
                Issue.record("Invalid historical configuration must fail before script creation")
                return previewAccess(PreviewScriptClient(tracks: []))
            },
            makePendingVerification: { _ in
                Issue.record("Invalid historical configuration must fail before store creation")
                return nil
            }
        )
        let runtime = try await makeRuntime(services: services)
        var invalid = AppConfiguration()
        mutate(&invalid)
        let configuration = FixPlanConfig.capture(
            configuration: invalid,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        switch entryPoint {
        case .sync:
            await #expect(throws: ConfigurationValidationError.self) {
                _ = try await runtime.makeSync(configuration: configuration, scope: scope(artist: "Probe Artist"))
            }
        case .preview:
            await #expect(throws: ConfigurationValidationError.self) {
                _ = try await runtime.makePreview(configuration: configuration, scope: scope(artist: "Probe Artist"))
            }
        case .write:
            await #expect(throws: ConfigurationValidationError.self) {
                _ = try await runtime.makeWrite(configuration: configuration, scope: scope(artist: "Probe Artist"))
            }
        }
    }

    @Test("run services use each submitted configuration")
    func usesSubmittedConfiguration() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeMusicAccess: { configuration in
                await probe.recordScriptConfig(configuration)
                return previewAccess(PreviewScriptClient(tracks: []))
            },
            makePendingVerification: { configuration in
                await probe.recordPendingConfig(configuration)
                return WorkflowPendingVerificationService(entries: [])
            }
        )
        let runtime = try await makeRuntime(services: services)
        let firstPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-config-first")
            .path
        let secondPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-config-second")
            .path
        let firstConfiguration = planConfiguration(path: firstPath, verificationDays: 7)
        let secondConfiguration = planConfiguration(path: secondPath, verificationDays: 21)

        _ = try await runtime.makeSync(
            configuration: firstConfiguration,
            scope: scope(artist: "First Artist")
        )
        _ = try await runtime.makePreview(
            configuration: firstConfiguration,
            scope: scope(artist: "First Artist")
        )
        _ = try await runtime.makeSync(
            configuration: secondConfiguration,
            scope: scope(artist: "Second Artist")
        )
        _ = try await runtime.makePreview(
            configuration: secondConfiguration,
            scope: scope(artist: "Second Artist")
        )

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [firstPath, secondPath])
        #expect(snapshot.verificationDays == [7, 21])
        #expect(snapshot.testArtists == [["First Artist"], ["Second Artist"]])
    }

    @Test("Headless preview uses the captured run confidence")
    func usesRunConfidence() async throws {
        let services = RunServiceFactory(
            makeMusicAccess: { _ in previewAccess(PreviewScriptClient(tracks: [])) },
            makePendingVerification: { _ in nil }
        )
        let factory = try await makeRuntime(services: services)
        let runScope = scope(artist: "Probe Artist")
        var appConfiguration = AppConfiguration()
        appConfiguration.yearRetrieval.logic.minConfidenceForNewYear = 95
        let configuration = FixPlanConfig.capture(
            configuration: appConfiguration,
            options: UpdateOptions(updateGenre: false, updateYear: true, minConfidence: 60),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let target = Track(
            id: "target",
            name: "Target",
            artist: "Probe Artist",
            album: "Consensus Album",
            year: nil,
            trackStatus: nil,
            releaseYear: 1970
        )
        let peer = Track(
            id: "peer",
            name: "Peer",
            artist: "Probe Artist",
            album: "Consensus Album",
            year: nil,
            trackStatus: nil,
            releaseYear: 1970
        )

        _ = try await factory.makeSync(configuration: configuration, scope: runScope)
        let preview = try await factory.makePreview(configuration: configuration, scope: runScope)
        let changes = try await preview.determineChanges(
            target,
            [target, peer],
            [],
            configuration.determinationOptions,
            YearRunScope()
        )

        let yearChange = try #require(changes.first { $0.changeType == .yearUpdate })
        #expect(yearChange.newValue == "1970")
        #expect(yearChange.confidence == 80)
    }

    @Test("run services rebuild when a configuration changes under the same ID")
    func rebuildsChangedConfig() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeMusicAccess: { configuration in
                await probe.recordScriptConfig(configuration)
                return previewAccess(PreviewScriptClient(tracks: []))
            },
            makePendingVerification: { _ in nil }
        )
        var first = AppConfiguration()
        let firstPath = FileManager.default.temporaryDirectory.appendingPathComponent("first").path
        let secondPath = FileManager.default.temporaryDirectory.appendingPathComponent("second").path
        first.paths.musicLibraryPath = firstPath
        first.development.testArtists = ["First Artist"]
        var second = first
        second.paths.musicLibraryPath = secondPath
        second.development.testArtists = ["Second Artist"]
        let id = UUID()

        let firstServices = try await services.prepareObservation(id: id, configuration: first)
        let secondServices = try await services.consumePreview(id: id, configuration: second)

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [firstPath, secondPath])
        #expect(snapshot.testArtists == [["First Artist"], ["Second Artist"]])
        _ = firstServices
        _ = secondServices
    }

    @Test("discarded run services are rebuilt")
    func rebuildsDiscardedRun() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeMusicAccess: { configuration in
                await probe.recordScriptConfig(configuration)
                return previewAccess(PreviewScriptClient(tracks: []))
            },
            makePendingVerification: { _ in nil }
        )
        var configuration = AppConfiguration()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("discarded-run").path
        configuration.paths.musicLibraryPath = path
        let id = UUID()

        _ = try await services.prepareObservation(id: id, configuration: configuration)
        await services.discard(id: id)
        _ = try await services.consumePreview(id: id, configuration: configuration)

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [path, path])
    }

    @Test("preview consumes submitted Discogs access")
    func consumesDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeMusicAccess: { _ in previewAccess(PreviewScriptClient(tracks: [])) },
            makePendingVerification: { _ in nil }
        )
        let accessStore = DiscogsAccessStore()
        let runtime = try await makeRuntime(services: services, accessStore: accessStore)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )
        await accessStore.save(
            .enabled(DiscogsClient(token: "submitted-token")),
            configurationID: configuration.id
        )

        _ = try await runtime.makePreview(configuration: configuration, scope: scope(artist: "Probe Artist"))

        #expect(await accessStore.consume(configurationID: configuration.id) == nil)
    }

    @Test("preview fails when submitted Discogs access is missing")
    func rejectsMissingDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeMusicAccess: { _ in previewAccess(PreviewScriptClient(tracks: [])) },
            makePendingVerification: { _ in nil }
        )
        let runtime = try await makeRuntime(services: services)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )

        do {
            _ = try await runtime.makePreview(configuration: configuration, scope: scope(artist: "Probe Artist"))
            Issue.record("Expected missing captured Discogs access to fail")
        } catch {
            #expect(error.localizedDescription == "Captured Discogs access is unavailable for this preview run")
        }
    }

    @Test("album-targeted preview restores full-scope artist evidence")
    func enrichesArtistContext() async throws {
        let rawTracks = musicKitArtistTracks()
        let script = PreviewScriptClient(tracks: appleScriptArtistTracks())
        let services = RunServiceFactory(
            makeMusicAccess: { _ in previewAccess(script) },
            makePendingVerification: { _ in nil }
        )
        let runtime = try await makeRuntime(services: services)
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: [],
            knownTrackCount: rawTracks.count,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "artist-context-test"
        )
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(updateGenre: true, updateYear: false),
            capturedAt: Date(timeIntervalSince1970: 100),
            albumTarget: FixPlanAlbumTarget(artist: "Artist", album: "Later Album")
        )
        _ = try await runtime.makeSync(configuration: configuration, scope: scope)
        let previewRuntime = try await runtime.makePreview(configuration: configuration, scope: scope)
        let admission = try unitAdmission(scope: scope, tracks: rawTracks)
        let producer = FixPlanProducer(dependencies: FixPlanProducer.Dependencies(
            loadAdmission: { _, _ in .admitted(admission, tracks: rawTracks) },
            makeRuntime: { _, _ in
                FixPlanProducer.Runtime(
                    refreshIdentity: previewRuntime.refreshIdentity,
                    albumContext: previewRuntime.albumContext,
                    artistContext: previewRuntime.artistContext,
                    determineChanges: { track, albumTracks, artistTracks, options, yearRunScope in
                        if track.id == "target" {
                            #expect(artistTracks.map(\.id) == ["target"])
                        }
                        return try await previewRuntime.determineChanges(
                            track,
                            albumTracks,
                            artistTracks,
                            options,
                            yearRunScope
                        )
                    }
                )
            },
            savePlan: { _, _ in
                Issue.record("Distinct enriched album artists must not produce a genre plan")
            },
            now: { Date(timeIntervalSince1970: 200) }
        ))

        let production = try await producer.producePlan(
            sourceRunID: RunID(),
            scope: scope,
            configuration: configuration
        )

        #expect(production == .empty)
    }

    private func musicKitArtistTracks() -> [Track] {
        [
            Track(
                id: "source",
                name: "Source Song",
                artist: "Artist",
                album: "Earlier Album",
                genre: "Post-Punk"
            ),
            Track(
                id: "target",
                name: "Target Song",
                artist: "Artist",
                album: "Later Album"
            ),
        ]
    }

    private func appleScriptArtistTracks() -> [Track] {
        [
            Track(
                id: "as-source",
                name: "Source Song",
                artist: "Artist",
                album: "Earlier Album",
                genre: "Post-Punk",
                trackStatus: TrackKind.purchased.rawValue,
                albumArtist: "Various Artists",
                appleScriptID: "as-source"
            ),
            Track(
                id: "as-target",
                name: "Target Song",
                artist: "Artist",
                album: "Later Album",
                trackStatus: TrackKind.purchased.rawValue,
                albumArtist: "Artist",
                appleScriptID: "as-target"
            ),
        ]
    }

    private func unitAdmission(
        scope: ProcessingScopeSnapshot,
        tracks: [Track]
    ) throws -> ProcessingAdmission {
        let trackIDs = try tracks.map { track in
            try #require(MusicDatabaseTrackID(rawValue: track.id))
        }
        let membership = try MembershipFingerprint.make(ids: trackIDs)
        return ProcessingAdmission(
            scopeID: scope.id,
            certificate: ScopeCertificate(
                id: UUID(),
                revision: .initial,
                membership: membership,
                testArtists: scope.normalizedTestArtists,
                fieldSet: .processingV1,
                evidence: ScopeEvidence(
                    requestedFingerprint: membership.fingerprint,
                    observedFingerprint: membership.fingerprint,
                    trackCount: trackIDs.count
                ),
                observedAt: Date(timeIntervalSince1970: 100)
            ),
            maximumMetadataAge: nil
        )
    }

    @Test("discard removes submitted Discogs access")
    func discardsDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeMusicAccess: { _ in previewAccess(PreviewScriptClient(tracks: [])) },
            makePendingVerification: { _ in nil }
        )
        let accessStore = DiscogsAccessStore()
        let runtime = try await makeRuntime(services: services, accessStore: accessStore)
        let configuration = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )
        await accessStore.save(
            .enabled(DiscogsClient(token: "submitted-token")),
            configurationID: configuration.id
        )

        await runtime.discard(configuration)

        #expect(await accessStore.consume(configurationID: configuration.id) == nil)
    }

    private func makeRuntime(
        services: RunServiceFactory,
        accessStore: DiscogsAccessStore = DiscogsAccessStore()
    ) async throws -> RunRuntimeFactory {
        let container = try ModelContainerFactory.createInMemory()
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()
        let script = PreviewScriptClient(tracks: [])
        return RunRuntimeFactory(
            services: services,
            store: TrackDataStore(modelContainer: container),
            gate: FeatureGate(fixedTier: .pro),
            cache: cache,
            undo: UndoCoordinator(musicApp: script),
            mapper: TrackIDMapper(),
            reachability: nil,
            discogsAccessStore: accessStore,
            analytics: nil
        )
    }

    private func planConfiguration(path: String, verificationDays: Int) -> FixPlanConfig {
        var configuration = AppConfiguration()
        configuration.paths.musicLibraryPath = path
        configuration.processing.pendingVerificationIntervalDays = verificationDays
        return FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: TimeInterval(verificationDays))
        )
    }

    private func scope(artist: String) -> ProcessingScopeSnapshot {
        ProcessingScopeSnapshot.capture(
            requestedTestArtists: [artist],
            knownTrackCount: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            reason: "test"
        )
    }
}

private struct AlbumPreviewFixture {
    let appConfiguration: AppConfiguration
    let configuration: FixPlanConfig
    let scope: ProcessingScopeSnapshot
    let target: Track
    let runtime: RunRuntimeFactory
    let dependencies: AppDependencies
    let store: TrackDataStore
    let planStore: FixPlanDataStore
}

@MainActor
private func makeAlbumPreviewFixture() async throws -> AlbumPreviewFixture {
    let observedAt = Date()
    let tracks = albumPreviewTracks()
    var appConfiguration = AppConfiguration()
    appConfiguration.development.testArtists = [tracks.target.artist, tracks.context.artist]
    appConfiguration.cleaning.genreMappings = ["Rock": "Metal"]
    appConfiguration.genreUpdate.overrideExisting = true
    appConfiguration.yearRetrieval.enabled = false
    let configuration = FixPlanConfig.capture(
        configuration: appConfiguration,
        options: UpdateOptions(updateGenre: true, updateYear: false),
        capturedAt: observedAt,
        albumTarget: FixPlanAlbumTarget(artist: tracks.target.artist, album: tracks.target.album)
    )
    let scope = ProcessingScopeSnapshot.capture(
        requestedTestArtists: appConfiguration.development.testArtists,
        knownTrackCount: 2,
        createdAt: observedAt,
        reason: "album-preview-admission-test"
    )
    let container = try ModelContainerFactory.createInMemory()
    let store = TrackDataStore(modelContainer: container)
    try await store.initialize()
    let planStore = FixPlanDataStore(modelContainer: container)
    let cache = try GRDBCacheService.createInMemory()
    try await cache.initialize()
    let runtime = makeAlbumRuntime(
        tracks: [tracks.target, tracks.context],
        observedAt: observedAt,
        store: store,
        cache: cache
    )
    let dependencies = AppDependencies(
        configurationLoader: { appConfiguration },
        modelContainerFactory: ModelContainerFactory.createInMemory
    )
    dependencies.configureLibraryPersistenceForTesting(trackStore: store, fixPlanStore: planStore)
    return AlbumPreviewFixture(
        appConfiguration: appConfiguration,
        configuration: configuration,
        scope: scope,
        target: tracks.target,
        runtime: runtime,
        dependencies: dependencies,
        store: store,
        planStore: planStore
    )
}

private func albumPreviewTracks() -> (target: Track, context: Track) {
    let target = Track(
        id: "target",
        name: "Target Song",
        artist: "Probe Artist",
        album: "Target Album",
        genre: "Rock",
        dateAdded: Date(timeIntervalSince1970: 50),
        trackStatus: TrackKind.subscription.rawValue,
        appleScriptID: "target"
    )
    let context = Track(
        id: "context",
        name: "Context Song",
        artist: "Context Artist",
        album: "Context Album",
        genre: "Electronic",
        dateAdded: Date(timeIntervalSince1970: 40),
        trackStatus: TrackKind.subscription.rawValue,
        appleScriptID: "context"
    )
    return (target, context)
}

@MainActor
private func makeAlbumRuntime(
    tracks: [Track],
    observedAt: Date,
    store: TrackDataStore,
    cache: GRDBCacheService
) -> RunRuntimeFactory {
    let script = PreviewScriptClient(tracks: tracks)
    let services = RunServiceFactory(
        makeMusicAccess: { _ in
            RunMusicAccess(
                identifier: script,
                writer: script,
                observer: PreviewSyncObserver(tracks: tracks, observedAt: observedAt)
            )
        },
        makePendingVerification: { _ in nil }
    )
    return RunRuntimeFactory(
        services: services,
        store: store,
        gate: FeatureGate(fixedTier: .pro),
        cache: cache,
        undo: UndoCoordinator(musicApp: script),
        mapper: TrackIDMapper(),
        reachability: nil,
        discogsAccessStore: DiscogsAccessStore(),
        analytics: nil
    )
}

private enum RuntimeEntryPoint: CaseIterable {
    case sync, preview, write
}

private func previewAccess(_ scripts: PreviewScriptClient) -> RunMusicAccess {
    RunMusicAccess(identifier: scripts, writer: scripts, observer: MusicAppTestObserver(tracks: []))
}

private actor PreviewSyncObserver: MusicAppReading {
    private let tracks: [Track]
    private let observedAt: Date

    init(tracks: [Track], observedAt: Date) {
        self.tracks = tracks
        self.observedAt = observedAt
    }

    func observe(_ request: LibraryObservationRequest) throws -> LibraryObservation {
        let generation = try #require(LibraryGeneration(sourceValue: "album-preview-test"))
        let rows = tracks.compactMap { track -> LibraryTrackRow? in
            guard let databaseID = track.databaseID else { return nil }
            return LibraryTrackRow(
                databaseID: databaseID,
                metadata: LibraryTrackMetadata(
                    text: LibraryTrackText(
                        name: .value(track.name),
                        artist: .value(track.artist),
                        album: .value(track.album),
                        albumArtist: track.albumArtist.map(Observed.value) ?? .absent
                    ),
                    genre: track.genre.map(Observed.value) ?? .absent,
                    editableYear: track.year.map(Observed.value) ?? .absent,
                    releaseYear: track.releaseYear.map(Observed.value) ?? .absent,
                    dateAdded: track.dateAdded.map(Observed.value) ?? .absent,
                    lastModified: track.lastModified.map(Observed.value) ?? .absent,
                    status: track.trackStatus.map(Observed.value) ?? .absent
                )
            )
        }
        let currentIDs = Set(rows.map(\.databaseID))
        let identities = rows.map(\.identityRow)
        return LibraryObservation(
            tracks: rows,
            identities: identities,
            epoch: LibraryObservationEpoch(
                censusIDs: currentIDs,
                currentIDs: currentIDs,
                scope: request.scope,
                observedAt: observedAt,
                generation: generation
            ),
            coverage: LibraryObservationCoverage(
                membership: request.scope.source == .fullLibrary ? .full : .scoped(unobservedIDs: []),
                identity: IdentityCompleteness(requestedIDs: currentIDs, observedIDs: currentIDs),
                metadata: MetadataCompleteness(requestedIDs: currentIDs, observedIDs: currentIDs),
                issues: []
            )
        )
    }
}
