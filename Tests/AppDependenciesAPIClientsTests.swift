import Core
import Security
import Services
import Testing
@testable import Genre_Updater

@Suite("AppDependencies API clients")
@MainActor
struct AppDependenciesAPIClientsTests {
    @Test("Keychain Discogs failures are reported before fallback client creation")
    func keychainDiscogsFailuresAreReportedBeforeFallbackClientCreation() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        let expectedError = KeychainError.authenticationFailed(errSecUserCanceled)
        var capturedError: (any Error)?

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            keychainDiscogsClientFactory: { _, _ in
                throw expectedError
            },
            keychainErrorHandler: { error in
                capturedError = error
            }
        )

        let keychainError = try #require(capturedError as? KeychainError)
        #expect(keychainError == expectedError)
    }
}
