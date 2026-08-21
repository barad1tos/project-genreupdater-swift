import Core
import Services
import Testing
@testable import Genre_Updater

@Suite("API request policy composition")
@MainActor
struct APIRequestPolicyTests {
    @Test("Configured provider rates compose one-token paced clients")
    func wiresProviderPacing() async throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "configured-token"
        configuration.yearRetrieval.rateLimits.discogsRequestsPerMinute = 12000
        configuration.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond = 200
        configuration.yearRetrieval.rateLimits.itunesRequestsPerSecond = 200
        let service = DashboardStateAPIService()
        var capturedDiscogs: TokenBucketRateLimiter?
        var capturedMusicBrainz: TokenBucketRateLimiter?
        var capturedITunes: TokenBucketRateLimiter?
        let factories = APIClientFactoryOverrides(
            configuredDiscogsClientFactory: { token, contactEmail, rateLimiter, baseURL in
                capturedDiscogs = rateLimiter
                return DiscogsClient(
                    token: token,
                    contactEmail: contactEmail,
                    rateLimiter: rateLimiter,
                    baseURL: baseURL
                )
            },
            musicBrainzFactory: { _, _, rateLimiter, _, _ in
                capturedMusicBrainz = rateLimiter
                return service
            },
            catalogFactory: { _, rateLimiter, _ in
                capturedITunes = rateLimiter
                return service
            }
        )

        _ = AppDependencies.makeAPIOrchestrator(
            configuration: configuration,
            cache: nil,
            pendingVerificationService: nil,
            reachability: nil,
            factoryOverrides: factories
        )

        for limiter in [capturedDiscogs, capturedMusicBrainz, capturedITunes] {
            let limiter = try #require(limiter)
            #expect(await limiter.getStats().currentTokens == 1)
            _ = await limiter.acquire()
            #expect(await limiter.acquire() < .milliseconds(80))
        }
    }
}
