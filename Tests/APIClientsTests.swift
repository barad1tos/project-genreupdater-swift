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

    @Test("Captured Discogs access is not reloaded during execution")
    func freezesDiscogsAccess() async {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        let headerProbe = AuthHeaderProbe()
        CapturedAuthURLProtocol.requestHandler = { request in
            headerProbe.append(request.value(forHTTPHeaderField: "Authorization"))
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, Data(#"{"results":[]}"#.utf8))
        }
        defer { CapturedAuthURLProtocol.requestHandler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        var keychainReadCount = 0
        let captured = AppDependencies.captureDiscogsAccess(
            configuration: configuration,
            factoryOverrides: APIClientFactoryOverrides(keychainDiscogsClientFactory: { contactEmail, limiter, url in
                keychainReadCount += 1
                return DiscogsClient(
                    token: "submitted-token",
                    contactEmail: contactEmail,
                    session: session,
                    rateLimiter: limiter,
                    baseURL: url
                )
            })
        )

        let orchestrator = AppDependencies.makePreviewAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            discogsAccess: captured
        )

        #expect(captured.isEnabled)
        #expect(keychainReadCount == 1)
        #expect(!orchestrator.disabledSources.contains(.discogs))
        _ = await orchestrator.getAlbumYear(
            artist: "Submitted Artist",
            album: "Submitted Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(!headerProbe.headers.isEmpty)
        #expect(headerProbe.headers.allSatisfy { $0 == "Discogs token=submitted-token" })
    }

    @Test("Captured missing Discogs access stays disabled")
    func freezesMissingDiscogsAccess() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        var keychainReadCount = 0
        let captured = AppDependencies.captureDiscogsAccess(
            configuration: configuration,
            factoryOverrides: APIClientFactoryOverrides(keychainDiscogsClientFactory: { contactEmail, limiter, url in
                keychainReadCount += 1
                return DiscogsClient(contactEmail: contactEmail, rateLimiter: limiter, baseURL: url)
            })
        )

        let orchestrator = AppDependencies.makePreviewAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            discogsAccess: captured
        )

        #expect(!captured.isEnabled)
        #expect(keychainReadCount == 1)
        #expect(orchestrator.disabledSources.contains(.discogs))
    }
}

private final class AuthHeaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []

    var headers: [String?] {
        lock.withLock { values }
    }

    func append(_ value: String?) {
        lock.withLock { values.append(value) }
    }
}

private final class CapturedAuthURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (URLResponse, Data))?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
