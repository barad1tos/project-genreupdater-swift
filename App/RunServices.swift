import Core
import Foundation
import Services

struct RunServices {
    let scripts: any AppleScriptClient
    let pendingVerification: (any PendingVerificationService)?
    let readProvider: (any LibraryReadProvider)?
}

/// Caches one serialized run between sync and preview; TriggerArbiter prevents run interleaving.
actor RunServiceFactory {
    private struct PreparedRun {
        let id: UUID
        let configuration: Data
        let services: RunServices
    }

    private let makeScripts: @Sendable (AppConfiguration) async throws -> any AppleScriptClient
    private let makePendingVerification: @Sendable (AppConfiguration) async throws
        -> (any PendingVerificationService)?
    private let makeReadProvider: @Sendable (AppConfiguration) -> (any LibraryReadProvider)?
    private var preparedRun: PreparedRun?

    init(
        makeScripts: @escaping @Sendable (AppConfiguration) async throws -> any AppleScriptClient,
        makePendingVerification: @escaping @Sendable (AppConfiguration) async throws
            -> (any PendingVerificationService)?,
        makeReadProvider: @escaping @Sendable (AppConfiguration) -> (any LibraryReadProvider)? = { _ in nil }
    ) {
        self.makeScripts = makeScripts
        self.makePendingVerification = makePendingVerification
        self.makeReadProvider = makeReadProvider
    }

    func prepare(id: UUID, configuration: AppConfiguration) async throws -> RunServices {
        let encodedConfiguration = try encode(configuration)
        if let preparedRun,
           preparedRun.id == id,
           preparedRun.configuration == encodedConfiguration {
            return preparedRun.services
        }

        let services = try await build(configuration: configuration)
        preparedRun = PreparedRun(id: id, configuration: encodedConfiguration, services: services)
        return services
    }

    func consume(id: UUID, configuration: AppConfiguration) async throws -> RunServices {
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
        let scripts = try await makeScripts(configuration)
        let pendingVerification = try await makePendingVerification(configuration)
        return RunServices(
            scripts: scripts,
            pendingVerification: pendingVerification,
            readProvider: makeReadProvider(configuration)
        )
    }

    private func encode(_ configuration: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(configuration)
    }
}
