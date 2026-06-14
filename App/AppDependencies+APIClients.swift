// AppDependencies+APIClients.swift — API client factory helpers

import Core
import Foundation
import Services

private let apiClientLog = AppLogger.make(category: "dependencies")

enum DiscogsCredentialIssue: Equatable {
    case keychain(KeychainError)
    case other(String)

    init(error: any Error) {
        if let keychainError = error as? KeychainError {
            self = .keychain(keychainError)
        } else {
            self = .other(error.localizedDescription)
        }
    }

    var message: String {
        switch self {
        case .keychain(.authenticationFailed):
            "Keychain authentication was cancelled or failed. Discogs is running without the saved token."
        case .keychain(.unprotectedItemRequiresResave):
            "The saved Discogs token must be saved again to require local authentication."
        case .keychain(.invalidTokenData):
            "The saved Discogs token data is invalid. Delete it and save the token again."
        case let .keychain(error):
            "Failed to load the saved Discogs token: \(error.localizedDescription)"
        case let .other(description):
            "Failed to load the saved Discogs token: \(description)"
        }
    }
}

extension AppDependencies {
    static func makeAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        pendingVerificationService: (any PendingVerificationService)?,
        reachability: NetworkReachabilityMonitor?,
        keychainDiscogsClientFactory: (
            _ contactEmail: String,
            _ rateLimiter: TokenBucketRateLimiter?
        ) throws -> DiscogsClient = { contactEmail, rateLimiter in
            try DiscogsClient.fromKeychain(
                contactEmail: contactEmail,
                rateLimiter: rateLimiter
            )
        },
        keychainErrorHandler: (any Error) -> Void = { error in
            apiClientLog
                .error("Failed to load Discogs token from Keychain: \(error.localizedDescription, privacy: .public)")
        },
        discogsCredentialIssueHandler: (DiscogsCredentialIssue?) -> Void = { _ in }
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
        let discogsClient: DiscogsClient
        if configuredDiscogsToken.isEmpty {
            do {
                discogsClient = try keychainDiscogsClientFactory(
                    contactEmail,
                    discogsRateLimiter
                )
                discogsCredentialIssueHandler(nil)
            } catch {
                keychainErrorHandler(error)
                discogsCredentialIssueHandler(DiscogsCredentialIssue(error: error))
                discogsClient = DiscogsClient(
                    contactEmail: contactEmail,
                    rateLimiter: discogsRateLimiter
                )
            }
        } else {
            discogsCredentialIssueHandler(nil)
            discogsClient = DiscogsClient(
                token: configuredDiscogsToken,
                contactEmail: contactEmail,
                rateLimiter: discogsRateLimiter
            )
        }

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
