import Core
import Foundation
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

        #expect(capturedIssue == nil)
    }

    @Test("Missing Keychain Discogs token reports a credential issue and disables Discogs")
    func missingKeychainDiscogsTokenReportsCredentialIssue() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var capturedIssue: DiscogsCredentialIssue?

        let orchestrator = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
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

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
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

        #expect(capturedIssue == nil)
        #expect(capturedBaseURL?.host == "sandbox.discogs.com")
    }

    @Test("Configured Discogs API host is passed to Keychain client factory")
    func configuredDiscogsAPIHostIsPassedToKeychainFactory() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        configuration.yearRetrieval.apiAuth.discogsBaseHost = "sandbox.discogs.com"
        var capturedBaseURL: URL?

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
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

        let baseURL = try #require(capturedBaseURL)
        #expect(baseURL.scheme == "https")
        #expect(baseURL.host == "sandbox.discogs.com")
    }
}
