import Core
import Foundation
import OSLog
import Services

private let previewProducerLog = Logger(subsystem: "com.genreupdater", category: "preview-producer")

extension AppDependencies {
    func captureFixPlanConfig(
        at date: Date,
        hasDiscogsAccess: Bool,
        albumTarget: FixPlanAlbumTarget? = nil
    ) -> FixPlanConfig {
        FixPlanConfig.capture(
            configuration: config,
            options: previewRunOptions(),
            capturedAt: date,
            discogsCredentialRevision: DiscogsClient.credentialRevision,
            hasDiscogsAccess: hasDiscogsAccess,
            albumTarget: albumTarget
        )
    }

    func makePreviewProducer(runtime: RunRuntimeFactory?)
        -> (@Sendable (
            RunID,
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> FixPlanProduction)? {
        guard let runtime,
              let trackStore,
              let fixPlanStore
        else {
            previewProducerLog.warning("Preview producer unavailable: missing runtime or stores")
            assertionFailure("Preview producer unavailable: missing runtime or stores")
            return nil
        }

        return makePreviewProducer(dependencies: FixPlanProducer.Dependencies(
            loadTracks: { try await trackStore.loadAllTracks() },
            makeRuntime: { configuration, scope in
                try await runtime.makePreview(configuration: configuration, scope: scope)
            },
            savePlan: { try await fixPlanStore.savePlan($0, initialDecision: $1) },
            now: { Date() }
        ))
    }

    func makePreviewProducer(
        dependencies producerDependencies: FixPlanProducer.Dependencies
    )
        -> @Sendable (
            RunID,
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> FixPlanProduction {
        let producer = FixPlanProducer(dependencies: producerDependencies)
        return { [producer] runID, scope, configuration in
            try await producer.producePlan(
                sourceRunID: runID,
                scope: scope,
                configuration: configuration
            )
        }
    }

    func previewRunOptions() -> UpdateOptions {
        let selection = config.processing.defaultUpdateBehavior.enabledTargets
        return PreviewRunOptions.make(
            configuration: config,
            updateGenre: selection.updateGenre,
            updateYear: selection.updateYear
        )
    }
}
