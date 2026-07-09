import Core
import Foundation
import Security
import Services
import Testing
@testable import Genre_Updater

@Suite("AppDependencies API clients")
@MainActor
struct APIClientsTests {
    @Test("Keychain Discogs failures are reported before fallback client creation")
    func keychainDiscogsFailuresAreReportedBeforeFallbackClientCreation() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        let expectedError = KeychainError.authenticationFailed(errSecUserCanceled)
        var capturedError: (any Error)?
        var capturedIssue: DiscogsCredentialIssue?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { _, _, _ in
                throw expectedError
            },
            keychainErrorHandler: { error in
                capturedError = error
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
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
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    token: "saved-token",
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedIssue == nil)
    }

    @Test("Missing Keychain Discogs token reports a credential issue and disables Discogs")
    func missingKeychainDiscogsTokenReportsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var capturedIssue: DiscogsCredentialIssue?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        let orchestrator = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedIssue == .missingToken)
        #expect(orchestrator.disabledSources.contains(.discogs))
    }

    @Test("Configured Discogs token bypasses Keychain and clears the credential issue")
    func configuredDiscogsTokenBypassesKeychainAndClearsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.apiAuth.discogsBaseHost = "sandbox.discogs.com"
        var capturedIssue: DiscogsCredentialIssue? = .keychain(.invalidTokenData)
        var capturedBaseURL: URL?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { _, _, _ in
                throw KeychainError.authenticationFailed(errSecAuthFailed)
            },
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                capturedBaseURL = baseURL
                return DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            discogsCredentialIssueHandler: { issue in
                capturedIssue = issue
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        #expect(capturedIssue == nil)
        #expect(capturedBaseURL?.host == "sandbox.discogs.com")
    }

    @Test("Configured Discogs API host is passed to Keychain client factory")
    func configuredDiscogsAPIHostIsPassedToKeychainFactory() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        configuration.yearRetrieval.apiAuth.discogsBaseHost = "sandbox.discogs.com"
        var capturedBaseURL: URL?
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, rateLimiter, baseURL in
                capturedBaseURL = baseURL
                return DiscogsClient(
                    token: "saved-token",
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )

        let baseURL = try #require(capturedBaseURL)
        #expect(baseURL.scheme == "https")
        #expect(baseURL.host == "sandbox.discogs.com")
    }
}
