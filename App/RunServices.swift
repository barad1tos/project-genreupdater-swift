import Core
import Foundation
import Services

struct RunMusicAccess {
    let identifier: any MusicAppIdentifying
    let writer: any MusicAppMutating & MusicAppVerifying
    let observer: any MusicAppReading
}

private struct RunServices {
    let identifier: any MusicAppIdentifying
    let writer: any MusicAppMutating & MusicAppVerifying
    let observer: any MusicAppReading
    let pendingVerification: (any PendingVerificationService)?
}

struct RunObservationServices {
    let observer: any MusicAppReading
    let pendingVerification: (any PendingVerificationService)?
}

struct RunPreviewServices {
    let identifier: any MusicAppIdentifying
    let pendingVerification: (any PendingVerificationService)?
}

struct RunWriteServices {
    let writer: any MusicAppMutating & MusicAppVerifying
    let pendingVerification: (any PendingVerificationService)?
}

/// Caches one serialized run between sync and preview; TriggerArbiter prevents run interleaving.
actor RunServiceFactory {
    private struct PreparedRun {
        let id: UUID
        let configuration: Data
        let services: RunServices
    }

    private let makeMusicAccess: @Sendable (AppConfiguration) async throws -> RunMusicAccess
    private let makePendingVerification: @Sendable (AppConfiguration) async throws
        -> (any PendingVerificationService)?
    private var preparedRun: PreparedRun?

    init(
        makeMusicAccess: @escaping @Sendable (AppConfiguration) async throws -> RunMusicAccess,
        makePendingVerification: @escaping @Sendable (AppConfiguration) async throws
            -> (any PendingVerificationService)?
    ) {
        self.makeMusicAccess = makeMusicAccess
        self.makePendingVerification = makePendingVerification
    }

    func prepareObservation(id: UUID, configuration: AppConfiguration) async throws -> RunObservationServices {
        let encodedConfiguration = try encode(configuration)
        if let preparedRun,
           preparedRun.id == id,
           preparedRun.configuration == encodedConfiguration {
            return observationServices(preparedRun.services)
        }

        let services = try await build(configuration: configuration)
        preparedRun = PreparedRun(id: id, configuration: encodedConfiguration, services: services)
        return observationServices(services)
    }

    func consumePreview(id: UUID, configuration: AppConfiguration) async throws -> RunPreviewServices {
        let services = try await consume(id: id, configuration: configuration)
        return RunPreviewServices(
            identifier: services.identifier,
            pendingVerification: services.pendingVerification
        )
    }

    func consumeWrite(id: UUID, configuration: AppConfiguration) async throws -> RunWriteServices {
        let services = try await consume(id: id, configuration: configuration)
        return RunWriteServices(
            writer: services.writer,
            pendingVerification: services.pendingVerification
        )
    }

    private func consume(id: UUID, configuration: AppConfiguration) async throws -> RunServices {
        let encodedConfiguration = try encode(configuration)
        if let preparedRun,
           preparedRun.id == id,
           preparedRun.configuration == encodedConfiguration {
            let services = preparedRun.services
            self.preparedRun = nil
            return services
        }

        if let preparedRun {
            assert(preparedRun.id == id, "Run services require serialized consumption")
        }
        preparedRun = nil
        return try await build(configuration: configuration)
    }

    func discard(id: UUID) {
        guard preparedRun?.id == id else { return }
        preparedRun = nil
    }

    private func build(configuration: AppConfiguration) async throws -> RunServices {
        let musicAccess = try await makeMusicAccess(configuration)
        let pendingVerification = try await makePendingVerification(configuration)
        return RunServices(
            identifier: musicAccess.identifier,
            writer: musicAccess.writer,
            observer: musicAccess.observer,
            pendingVerification: pendingVerification
        )
    }

    private func observationServices(_ services: RunServices) -> RunObservationServices {
        RunObservationServices(
            observer: services.observer,
            pendingVerification: services.pendingVerification
        )
    }

    private func encode(_ configuration: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }
}

extension AppDependencies {
    func makeLibrarySyncService(
        bridge: AppleScriptBridge,
        store: any TrackStateStore,
        effectDrain: MirrorEffectDrain?
    ) throws -> LibrarySyncService {
        try LibrarySyncService(
            trackStore: store,
            effectDrain: effectDrain,
            pendingVerificationService: pendingVerificationService,
            librarySnapshotService: librarySnapshotService,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(configuration: config),
            observer: MusicAppObserver(bridge: bridge)
        )
    }

    func makeBatchProcessor(checkpoint: CheckpointManager, gate: FeatureGate) -> BatchProcessor {
        BatchProcessor(
            checkpointManager: checkpoint,
            featureGate: gate,
            processingConfiguration: BatchProcessingConfiguration(configuration: config),
            analytics: analyticsService
        )
    }
}
