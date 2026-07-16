import Core
import Foundation
import OSLog
import Services

private let previewProducerLog = Logger(subsystem: "com.genreupdater", category: "preview-producer")

extension AppDependencies {
    func capturePreviewConfig(
        at date: Date,
        hasDiscogsAccess: Bool
    ) -> FixPlanConfig {
        FixPlanConfig.capture(
            configuration: config,
            options: previewRunOptions(),
            capturedAt: date,
            discogsCredentialRevision: DiscogsClient.credentialRevision,
            hasDiscogsAccess: hasDiscogsAccess
        )
    }

    func makePreviewProducer(runtime: RunRuntimeFactory?)
        -> (@Sendable (
            RunID,
            ProcessingScopeSnapshot,
            FixPlanConfig
        ) async throws -> FixPlanProduction)? {
        let missingInputs = missingPreviewInputs()
        guard missingInputs.isEmpty,
              let runtime,
              let trackStore,
              let fixPlanStore
        else {
            let missingList = missingInputs.joined(separator: ", ")
            previewProducerLog.warning("Preview producer unavailable: missing \(missingList, privacy: .public)")
            assertionFailure("Preview producer unavailable: missing \(missingList)")
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
            scriptInstaller == nil ? "scriptInstaller" : nil,
            modelContainer == nil ? "modelContainer" : nil,
            featureGate == nil ? "featureGate" : nil,
            cacheService == nil ? "cacheService" : nil,
            undoCoordinator == nil ? "undoCoordinator" : nil,
            trackStore == nil ? "trackStore" : nil,
            fixPlanStore == nil ? "fixPlanStore" : nil,
            trackIDMapper == nil ? "trackIDMapper" : nil
        ].compactMap(\.self)
    }
}
