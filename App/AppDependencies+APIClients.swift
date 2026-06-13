// AppDependencies+APIClients.swift — API client factory helpers

import Core
import Services

extension AppDependencies {
    static func makeAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        pendingVerificationService: (any PendingVerificationService)?,
        reachability: NetworkReachabilityMonitor?
    ) -> APIOrchestrator {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let musicBrainzClient = MusicBrainzClient(
            appName: apiAuth.musicBrainzAppName,
            contactEmail: contactEmail,
            rateLimiter: makeMusicBrainzRateLimiter(configuration: configuration)
        )
        let discogsRateLimiter = makeDiscogsRateLimiter(configuration: configuration)
        let configuredDiscogsToken = APIAuthReferenceResolver.resolve(apiAuth.discogsTokenReference)
        let discogsClient = configuredDiscogsToken.isEmpty
            ? ((try? DiscogsClient.fromKeychain(
                contactEmail: contactEmail,
                rateLimiter: discogsRateLimiter
            )) ?? DiscogsClient(
                contactEmail: contactEmail,
                rateLimiter: discogsRateLimiter
            ))
            : DiscogsClient(
                token: configuredDiscogsToken,
                contactEmail: contactEmail,
                rateLimiter: discogsRateLimiter
            )

        return APIOrchestrator(
            musicBrainz: musicBrainzClient,
            discogs: discogsClient,
            appleMusic: makeAppleMusicSearchClient(configuration: configuration),
            reachability: reachability,
            cache: cache,
            pendingVerificationService: pendingVerificationService,
            maxVerificationAttempts: configuration.yearRetrieval.fallback.maxVerificationAttempts,
            negativeResultTTL: configuration.caching.negativeResultTTL,
            maxConcurrentSourceCalls: configuration.yearRetrieval.rateLimits.concurrentAPICalls,
            maxAPIRetries: configuration.runtime.maxRetries,
            apiRetryDelaySeconds: configuration.runtime.retryDelaySeconds,
            sourcePriorityConfiguration: APISourcePriorityConfiguration(configuration: configuration)
        )
    }

    static func makeAppleMusicSearchClient(configuration: AppConfiguration) -> AppleMusicSearchClient {
        let itunesSearch = configuration.yearRetrieval.itunesSearch
        return AppleMusicSearchClient(
            countryCode: itunesSearch.normalizedCountryCode,
            entity: itunesSearch.entity,
            limit: itunesSearch.clampedLimit,
            lookupFallbackEnabled: itunesSearch.lookupFallbackEnabled
        )
    }

    private static func makeMusicBrainzRateLimiter(configuration: AppConfiguration) -> TokenBucketRateLimiter {
        makeRateLimiter(
            requests: configuration.yearRetrieval.rateLimits.musicbrainzRequestsPerSecond,
            perSeconds: 1
        )
    }

    private static func makeDiscogsRateLimiter(configuration: AppConfiguration) -> TokenBucketRateLimiter {
        makeRateLimiter(
            requests: Double(configuration.yearRetrieval.rateLimits.discogsRequestsPerMinute),
            perSeconds: 60
        )
    }

    private static func makeRateLimiter(
        requests: Double,
        perSeconds windowSizeSeconds: Double
    ) -> TokenBucketRateLimiter {
        let sanitizedRequests = max(1, requests)
        let refillMilliseconds = max(1, Int((windowSizeSeconds / sanitizedRequests) * 1000))

        return TokenBucketRateLimiter(
            maxTokens: Int(sanitizedRequests.rounded(.up)),
            refillInterval: .milliseconds(refillMilliseconds)
        )
    }
}
