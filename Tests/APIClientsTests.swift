import Core
import Foundation
import Security
import Services
import Testing
@testable import Genre_Updater

@Suite("AppDependencies API clients", .serialized)
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

    @Test("Configured reissue evidence reaches the composed Discogs client")
    func composesDiscogsReissueEvidence() async {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.preferredAPI = .discogs
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.reissueDetection.reissueKeywords = ["anniversary"]
        CapturedAuthURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            let data = Data(
                """
                {"results":[{"id":7,"title":"Test Artist - Test Album (Anniversary)","year":2020,
                "type":"release","format":["Album"]}]}
                """
                .utf8
            )
            return (response, data)
        }
        defer { CapturedAuthURLProtocol.requestHandler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let factoryOverrides = APIClientFactoryOverrides(
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    session: session,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            musicBrainz: DashboardStateAPIService(),
            appleMusic: DashboardStateAPIService()
        )

        let orchestrator = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factoryOverrides
        )
        let candidates = await orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(candidates.first?.isReissue == true)
    }

    @Test("Captured Discogs access is not reloaded during execution")
    func freezesDiscogsAccess() async {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = ""
        let headerProbe = AuthHeaderProbe()
        CapturedAuthURLProtocol.requestHandler = { request in
            try makeDiscogsResponse(for: request, probe: headerProbe)
        }
        defer { CapturedAuthURLProtocol.requestHandler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        var keychainReadCount = 0
        let factoryOverrides = APIClientFactoryOverrides(
            keychainDiscogsClientFactory: { contactEmail, limiter, url in
                keychainReadCount += 1
                return DiscogsClient(
                    token: "submitted-token",
                    contactEmail: contactEmail,
                    session: session,
                    rateLimiter: limiter,
                    baseURL: url
                )
            },
            musicBrainz: DashboardStateAPIService(),
            appleMusic: DashboardStateAPIService()
        )
        let captured = AppDependencies.captureDiscogsAccess(
            configuration: configuration,
            factoryOverrides: factoryOverrides
        )

        let orchestrator = AppDependencies.makeCapturedAPI(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            discogsAccess: captured,
            factoryOverrides: factoryOverrides
        )

        #expect(captured.isEnabled)
        #expect(keychainReadCount == 1)
        #expect(!orchestrator.disabledSources.contains(.discogs))
        let result = await orchestrator.getAlbumYear(
            artist: "Submitted Artist",
            album: "Submitted Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(result.year == 2001)
        #expect(keychainReadCount == 1)
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

        let orchestrator = AppDependencies.makeCapturedAPI(
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

    @Test("Raw API misses expire on the short transport TTL")
    func rawMissExpires() async throws {
        let fixture = try await makeCacheJourney()
        defer {
            CapturedAuthURLProtocol.requestHandler = nil
            fixture.session.invalidateAndCancel()
        }

        let first = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let immediate = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        #expect(first.isEmpty)
        #expect(immediate.isEmpty)
        #expect(fixture.probe.requestCount == 1)

        try await Task.sleep(for: .milliseconds(1100))
        let refreshed = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(refreshed.map(\.year) == [2024])
        #expect(fixture.probe.requestCount == 2)
    }

    @Test("Disabling confirmed-miss caching retries every eligible lookup")
    func offRetriesImmediately() async throws {
        let fixture = try await makeCacheJourney(negativeTTL: 0)
        defer {
            CapturedAuthURLProtocol.requestHandler = nil
            fixture.session.invalidateAndCancel()
        }

        let first = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let retried = await fixture.orchestrator.getReleaseCandidates(
            artist: "Test Artist",
            album: "Test Album",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(first.isEmpty)
        #expect(retried.map(\.year) == [2024])
        #expect(fixture.probe.requestCount == 2)
    }
}

@MainActor
private func makeCacheJourney(negativeTTL: TimeInterval = 1) async throws -> (
    orchestrator: APIOrchestrator,
    probe: RawRequestProbe,
    session: URLSession
) {
    var configuration = AppConfiguration()
    configuration.yearRetrieval.preferredAPI = .itunes
    configuration.caching.defaultTTLSeconds = 10
    configuration.caching.negativeResultTTL = negativeTTL
    configuration.processing.cacheTTLDays = 36500
    configuration.runtime.maxRetries = 0
    let cache = try GRDBCacheService.createInMemory(defaultGenericTTL: 10)
    try await cache.initialize()
    let rawCache = try #require(AppDependencies.makeRawCache(
        configuration: configuration,
        cache: cache
    ))
    let probe = RawRequestProbe()
    CapturedAuthURLProtocol.requestHandler = { request in
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, probe.nextPayload())
    }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [CapturedAuthURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    let catalog = CatalogSearchClient(
        session: session,
        lookupFallbackEnabled: false,
        rawRequestCache: rawCache
    )
    var orchestratorConfiguration = APIOrchestratorConfiguration(configuration: configuration)
    orchestratorConfiguration.cache = cache
    orchestratorConfiguration.disabledSources = [.musicBrainz, .discogs]
    let unavailable = DashboardStateAPIService()
    let orchestrator = APIOrchestrator(
        musicBrainz: unavailable,
        discogs: unavailable,
        appleMusic: catalog,
        configuration: orchestratorConfiguration
    )
    return (orchestrator, probe, session)
}

private func makeDiscogsResponse(
    for request: URLRequest,
    probe: AuthHeaderProbe
) throws -> (URLResponse, Data) {
    probe.append(request.value(forHTTPHeaderField: "Authorization"))
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    ))
    let data = Data(
        #"{"results":[{"id":1,"title":"Submitted Artist - Submitted Album","year":"2001","type":"master"}]}"#
            .utf8
    )
    return (response, data)
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

private final class RawRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int {
        lock.withLock { count }
    }

    func nextPayload() -> Data {
        lock.withLock {
            count += 1
            guard count > 1 else {
                return Data(#"{"resultCount":0,"results":[]}"#.utf8)
            }
            return Data(
                """
                {
                  "resultCount": 1,
                  "results": [{
                    "artistName": "Test Artist",
                    "collectionName": "Test Album",
                    "releaseDate": "2024-01-01T00:00:00Z"
                  }]
                }
                """
                .utf8
            )
        }
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

    override func stopLoading() {
        // Responses are delivered synchronously, so there is no pending work to cancel.
    }
}
