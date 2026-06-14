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
        var capturedIssue: DiscogsCredentialIssue?

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
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        let keychainError = try #require(capturedError as? KeychainError)
        #expect(keychainError == expectedError)
        #expect(capturedIssue == .keychain(expectedError))
    }

    @Test("Successful Keychain Discogs load clears the credential issue")
    func successfulKeychainDiscogsLoadClearsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var capturedIssue: DiscogsCredentialIssue? = .keychain(.invalidTokenData)

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            keychainDiscogsClientFactory: { contactEmail, rateLimiter in
                DiscogsClient(
                    token: "saved-token",
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        #expect(capturedIssue == nil)
    }

    @Test("Configured Discogs token bypasses Keychain and clears the credential issue")
    func configuredDiscogsTokenBypassesKeychainAndClearsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        var capturedIssue: DiscogsCredentialIssue? = .keychain(.invalidTokenData)

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            keychainDiscogsClientFactory: { _, _ in
                throw KeychainError.authenticationFailed(errSecAuthFailed)
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        #expect(capturedIssue == nil)
    }
}
