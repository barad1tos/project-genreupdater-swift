import Core
import Foundation
import OSLog
import Services

private let previewProducerLog = Logger(subsystem: "com.genreupdater", category: "preview-producer")

struct WriteIdentityRefresher {
    let mapper: TrackIDMapper
    let client: any AppleScriptClient

    func refresh(
        tracks: [Track],
        scope: ProcessingScopeSnapshot,
        config: AppleScriptConfig
    ) async throws {
        let mappedCount = try await mapper.refreshMapping(
            musicKitTracks: tracks,
            appleScriptClient: client,
            batchSize: config.batchProcessing.idsBatchSize,
            allTrackIDsTimeout: config.timeouts.fullLibraryFetch,
            tracksByIDsTimeout: config.timeouts.idsBatchFetch,
            testArtists: scope.normalizedTestArtists,
            mergeExisting: true
        )
        previewProducerLog.info(
            "Track ID mapping refreshed: \(mappedCount, privacy: .public)/\(tracks.count, privacy: .public)"
        )
    }
}

extension AppDependencies {
    func makePreviewProducer()
        -> (@Sendable (RunID, ProcessingScopeSnapshot) async throws -> FixPlanProduction)? {
        let missingInputs = missingPreviewInputs()
        guard missingInputs.isEmpty,
              let updateCoordinator,
              let trackStore,
              let fixPlanStore,
              let mapper = trackIDMapper,
              let scriptClient = applescriptBridge
        else {
            let missingList = missingInputs.joined(separator: ", ")
            previewProducerLog.warning("Preview producer unavailable: missing \(missingList, privacy: .public)")
            assertionFailure("Preview producer unavailable: missing \(missingList)")
            return nil
        }
        let identityRefresher = WriteIdentityRefresher(mapper: mapper, client: scriptClient)

        return makePreviewProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { try await trackStore.loadAllTracks() },
            refreshWriteIdentity: { [weak self, identityRefresher] tracks, scope in
                guard let self else {
                    throw PreviewRunError.appDependenciesReleased
                }
                try await identityRefresher.refresh(
                    tracks: tracks,
                    scope: scope,
                    config: self.config.applescript
                )
            },
            albumContextTracksByTrackID: {
                await updateCoordinator.albumContextTracksByTrackID(for: $0, requiresMutationMetadata: false)
            },
            determineTrackChanges: {
                try await updateCoordinator.updateTrack(
                    $0,
                    albumTracks: $1,
                    artistTracks: $2,
                    options: $3,
                    dryRun: true
                )
            },
            savePlan: { try await fixPlanStore.savePlan($0, initialDecision: $1) },
            now: { Date() }
        ))
    }

    func makePreviewProducer(
        dependencies producerDependencies: FixPlanProducer.Dependencies,
        options fixedOptions: UpdateOptions? = nil
    )
        -> @Sendable (RunID, ProcessingScopeSnapshot) async throws -> FixPlanProduction {
        let producer = FixPlanProducer(dependencies: producerDependencies)
        return { [weak self, producer] runID, scope in
            guard let self else {
                throw PreviewRunError.appDependenciesReleased
            }
            let options: UpdateOptions = if let fixedOptions {
                fixedOptions
            } else {
                await self.previewRunOptions()
            }
            return try await producer.producePlan(sourceRunID: runID, scope: scope, options: options)
        }
    }

    func previewRunOptions() -> UpdateOptions {
        let selection = UpdateBehavior
            .resolved(from: UserDefaults.standard.string(forKey: AppStorageKey.defaultUpdateBehavior))
            .enabledTargets
        return PreviewRunOptions.make(
            configuration: config,
            updateGenre: selection.updateGenre,
            updateYear: selection.updateYear
        )
    }

    private func missingPreviewInputs() -> [String] {
        [
            applescriptBridge == nil ? "applescriptBridge" : nil,
            updateCoordinator == nil ? "updateCoordinator" : nil,
            trackStore == nil ? "trackStore" : nil,
            fixPlanStore == nil ? "fixPlanStore" : nil,
            trackIDMapper == nil ? "trackIDMapper" : nil
        ].compactMap(\.self)
    }
}
