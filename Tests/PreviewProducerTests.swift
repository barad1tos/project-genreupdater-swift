import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("Preview producer runtime")
@MainActor
struct PreviewProducerTests {
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
            $0.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 1e308
        }
    }

    @Test("Recovered batch-delay overflow fails before runtime services")
    func rejectsDelayOverflow() async throws {
        try await expectRuntimeRejection(at: .preview) {
            $0.processing.delayBetweenBatches = 1e308
        }
    }

    private func expectRuntimeRejection(
        at entryPoint: RuntimeEntryPoint,
        mutate: (inout AppConfiguration) -> Void = { $0.genreUpdate.batchSize = 0 }
    ) async throws {
        let services = RunServiceFactory(
            makeScripts: { _ in
                Issue.record("Invalid historical configuration must fail before script creation")
                return PreviewScriptClient(tracks: [])
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
            makeScripts: { configuration in
                await probe.recordScriptConfig(configuration)
                return PreviewScriptClient(tracks: [])
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

    @Test("run services rebuild when a configuration changes under the same ID")
    func rebuildsChangedConfig() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeScripts: { configuration in
                await probe.recordScriptConfig(configuration)
                return PreviewScriptClient(tracks: [])
            },
            makePendingVerification: { _ in nil },
            makeReadProvider: { configuration in
                ScopedReadProvider(artists: configuration.development.testArtists)
            }
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

        let firstServices = try await services.prepare(id: id, configuration: first)
        let secondServices = try await services.consume(id: id, configuration: second)

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [firstPath, secondPath])
        #expect(try await readArtists(firstServices) == ["First Artist"])
        #expect(try await readArtists(secondServices) == ["Second Artist"])
    }

    @Test("discarded run services are rebuilt")
    func rebuildsDiscardedRun() async throws {
        let probe = RunConfigProbe()
        let services = RunServiceFactory(
            makeScripts: { configuration in
                await probe.recordScriptConfig(configuration)
                return PreviewScriptClient(tracks: [])
            },
            makePendingVerification: { _ in nil }
        )
        var configuration = AppConfiguration()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("discarded-run").path
        configuration.paths.musicLibraryPath = path
        let id = UUID()

        _ = try await services.prepare(id: id, configuration: configuration)
        await services.discard(id: id)
        _ = try await services.consume(id: id, configuration: configuration)

        let snapshot = await probe.snapshot()
        #expect(snapshot.libraryPaths == [path, path])
    }

    @Test("preview consumes submitted Discogs access")
    func consumesDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeScripts: { _ in PreviewScriptClient(tracks: []) },
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
            makeScripts: { _ in PreviewScriptClient(tracks: []) },
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

    @Test("discard removes submitted Discogs access")
    func discardsDiscogsAccess() async throws {
        let services = RunServiceFactory(
            makeScripts: { _ in PreviewScriptClient(tracks: []) },
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

    private func readArtists(_ services: RunServices) async throws -> [String] {
        let provider = try #require(services.readProvider as? ScopedReadProvider)
        return provider.artists
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
            undo: UndoCoordinator(scriptBridge: script),
            mapper: TrackIDMapper(),
            reachability: nil,
            discogsAccessStore: accessStore
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

private enum RuntimeEntryPoint {
    case sync
    case preview
    case write
}
