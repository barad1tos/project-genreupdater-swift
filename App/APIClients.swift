import Core
import Foundation
import Services

private let apiClientLog = AppLogger.make(category: "dependencies")

enum DiscogsCredentialIssue: Equatable {
    case missingToken
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
        case .missingToken:
            "Discogs Personal Access Token is not configured. Discogs lookups are disabled until a token is saved."
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

struct APIClientFactoryOverrides {
    typealias DiscogsIssueHandler = @MainActor (DiscogsCredentialIssue?) -> Void
    typealias KeychainDiscogsClientFactory = (
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ baseURL: URL
    ) throws -> DiscogsClient
    typealias ConfiguredDiscogsClientFactory = (
        _ token: String,
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ baseURL: URL
    ) -> DiscogsClient

    var keychainDiscogsClientFactory: KeychainDiscogsClientFactory
    var configuredDiscogsClientFactory: ConfiguredDiscogsClientFactory
    var keychainErrorHandler: (any Error) -> Void
    var discogsCredentialIssueHandler: DiscogsIssueHandler

    init(
        keychainDiscogsClientFactory: @escaping KeychainDiscogsClientFactory = Self.makeKeychainDiscogsClient,
        configuredDiscogsClientFactory: @escaping ConfiguredDiscogsClientFactory = Self.makeConfiguredDiscogsClient,
        keychainErrorHandler: @escaping (any Error) -> Void = { error in
            apiClientLog.error(
                "Failed to load Discogs token from Keychain: \(error.localizedDescription, privacy: .public)"
            )
        },
        discogsCredentialIssueHandler: @escaping DiscogsIssueHandler = { _ in
            // Default factory use has no UI state to update; callers that own state inject a handler.
        }
    ) {
        self.keychainDiscogsClientFactory = keychainDiscogsClientFactory
        self.configuredDiscogsClientFactory = configuredDiscogsClientFactory
        self.keychainErrorHandler = keychainErrorHandler
        self.discogsCredentialIssueHandler = discogsCredentialIssueHandler
    }

    static func makeKeychainDiscogsClient(
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        baseURL: URL
    ) throws -> DiscogsClient {
        try DiscogsClient.fromKeychain(
            contactEmail: contactEmail,
            rateLimiter: rateLimiter,
            baseURL: baseURL
        )
    }

    static func makeConfiguredDiscogsClient(
        token: String,
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        baseURL: URL
    ) -> DiscogsClient {
        DiscogsClient(
            token: token,
            contactEmail: contactEmail,
            rateLimiter: rateLimiter,
            baseURL: baseURL
        )
    }
}

private struct DiscogsClientContext {
    let client: DiscogsClient
    let disabledSources: Set<APISource>
}

enum DiscogsAccess: Sendable {
    case enabled(DiscogsClient)
    case disabled

    var isEnabled: Bool {
        if case .enabled = self {
            true
        } else {
            false
        }
    }
}

actor DiscogsAccessStore {
    private var accessByConfigurationID: [UUID: DiscogsAccess] = [:]

    func save(_ access: DiscogsAccess, configurationID: UUID) {
        accessByConfigurationID[configurationID] = access
    }

    func consume(configurationID: UUID) -> DiscogsAccess? {
        accessByConfigurationID.removeValue(forKey: configurationID)
    }

    func discard(configurationID: UUID) {
        accessByConfigurationID.removeValue(forKey: configurationID)
    }
}

extension AppDependencies {
    static func makeAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        pendingVerificationService: (any PendingVerificationService)?,
        reachability: NetworkReachabilityMonitor?,
        factoryOverrides: APIClientFactoryOverrides = APIClientFactoryOverrides()
    ) -> APIOrchestrator {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let discogsContext = makeDiscogsClientContext(
            apiAuth: apiAuth,
            contactEmail: contactEmail,
            rateLimiter: makeDiscogsRateLimiter(configuration: configuration),
            factoryOverrides: factoryOverrides
        )
        return makeAPIOrchestrator(
            configuration: configuration,
            cache: cache,
            pendingVerificationService: pendingVerificationService,
            reachability: reachability,
            discogsContext: discogsContext
        )
    }

    static func makePreviewAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        pendingVerificationService: (any PendingVerificationService)?,
        reachability: NetworkReachabilityMonitor?,
        discogsAccess: DiscogsAccess
    ) -> APIOrchestrator {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let discogsContext = makeDiscogsClientContext(
            access: discogsAccess,
            apiAuth: apiAuth,
            contactEmail: contactEmail
        )
        return makeAPIOrchestrator(
            configuration: configuration,
            cache: cache,
            pendingVerificationService: pendingVerificationService,
            reachability: reachability,
            discogsContext: discogsContext
        )
    }

    private static func makeAPIOrchestrator(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        pendingVerificationService: (any PendingVerificationService)?,
        reachability: NetworkReachabilityMonitor?,
        discogsContext: DiscogsClientContext
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
        let orchestratorConfiguration = makeAPIOrchestratorConfiguration(
            configuration: configuration,
            cache: cache,
            pendingVerificationService: pendingVerificationService,
            reachability: reachability,
            disabledSources: discogsContext.disabledSources
        )

        return APIOrchestrator(
            services: APIOrchestratorServices(
                musicBrainz: musicBrainzClient,
                discogs: discogsContext.client,
                appleMusic: makeCatalogClient(configuration: configuration)
            ),
            configuration: orchestratorConfiguration
        )
    }

    static func captureDiscogsAccess(
        configuration: AppConfiguration,
        factoryOverrides: APIClientFactoryOverrides = APIClientFactoryOverrides()
    ) -> DiscogsAccess {
        let apiAuth = configuration.yearRetrieval.apiAuth
        let contactEmail = APIAuthReferenceResolver.resolve(
            apiAuth.contactEmailReference,
            fallbackUserDefaultsKey: "contactEmail"
        )
        let context = makeDiscogsClientContext(
            apiAuth: apiAuth,
            contactEmail: contactEmail,
            rateLimiter: makeDiscogsRateLimiter(configuration: configuration),
            factoryOverrides: factoryOverrides
        )
        return context.disabledSources.contains(.discogs) ? .disabled : .enabled(context.client)
    }

    private static func makeDiscogsClientContext(
        access: DiscogsAccess,
        apiAuth: APIAuthConfig,
        contactEmail: String
    ) -> DiscogsClientContext {
        switch access {
        case let .enabled(client):
            DiscogsClientContext(client: client, disabledSources: [])
        case .disabled:
            DiscogsClientContext(
                client: makeDisabledDiscogsClient(
                    contactEmail,
                    nil,
                    apiAuth.discogsBaseURL
                ),
                disabledSources: [.discogs]
            )
        }
    }

    private static func makeDiscogsClientContext(
        apiAuth: APIAuthConfig,
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        factoryOverrides: APIClientFactoryOverrides
    ) -> DiscogsClientContext {
        let discogsBaseURL = apiAuth.discogsBaseURL
        let configuredDiscogsToken = APIAuthReferenceResolver.resolve(apiAuth.discogsTokenReference)

        if configuredDiscogsToken.isEmpty {
            return makeKeychainDiscogsClientContext(
                contactEmail: contactEmail,
                rateLimiter: rateLimiter,
                baseURL: discogsBaseURL,
                factoryOverrides: factoryOverrides
            )
        }

        factoryOverrides.discogsCredentialIssueHandler(nil)
        return DiscogsClientContext(
            client: factoryOverrides.configuredDiscogsClientFactory(
                configuredDiscogsToken,
                contactEmail,
                rateLimiter,
                discogsBaseURL
            ),
            disabledSources: []
        )
    }

    private static func makeKeychainDiscogsClientContext(
        contactEmail: String,
        rateLimiter: TokenBucketRateLimiter?,
        baseURL: URL,
        factoryOverrides: APIClientFactoryOverrides
    ) -> DiscogsClientContext {
        do {
            let client = try factoryOverrides.keychainDiscogsClientFactory(contactEmail, rateLimiter, baseURL)
            guard client.isConfigured else {
                factoryOverrides.discogsCredentialIssueHandler(.missingToken)
                return DiscogsClientContext(
                    client: client,
                    disabledSources: [.discogs]
                )
            }

            factoryOverrides.discogsCredentialIssueHandler(nil)
            return DiscogsClientContext(client: client, disabledSources: [])
        } catch {
            factoryOverrides.keychainErrorHandler(error)
            factoryOverrides.discogsCredentialIssueHandler(DiscogsCredentialIssue(error: error))
            return DiscogsClientContext(
                client: makeDisabledDiscogsClient(contactEmail, rateLimiter, baseURL),
                disabledSources: [.discogs]
            )
        }
    }

    private static func makeAPIOrchestratorConfiguration(
        configuration: AppConfiguration,
        cache: (any CacheService)?,
        pendingVerificationService: (any PendingVerificationService)?,
        reachability: NetworkReachabilityMonitor?,
        disabledSources: Set<APISource>
    ) -> APIOrchestratorConfiguration {
        var orchestratorConfiguration = APIOrchestratorConfiguration(configuration: configuration)
        orchestratorConfiguration.reachability = reachability
        orchestratorConfiguration.cache = cache
        orchestratorConfiguration.pendingVerificationService = pendingVerificationService
        orchestratorConfiguration.disabledSources = disabledSources
        return orchestratorConfiguration
    }

    private static func makeDisabledDiscogsClient(
        _ contactEmail: String,
        _ rateLimiter: TokenBucketRateLimiter?,
        _ baseURL: URL
    ) -> DiscogsClient {
        DiscogsClient(contactEmail: contactEmail, rateLimiter: rateLimiter, baseURL: baseURL)
    }

    static func makeCatalogClient(configuration: AppConfiguration) -> CatalogSearchClient {
        let itunesSearch = configuration.yearRetrieval.itunesSearch
        return CatalogSearchClient(
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
