// AppDependencies+APIClients.swift — API client factory helpers

import Core
import Services

extension AppDependencies {
    static func makeAppleMusicSearchClient(configuration: AppConfiguration) -> AppleMusicSearchClient {
        let itunesSearch = configuration.yearRetrieval.itunesSearch
        return AppleMusicSearchClient(
            countryCode: itunesSearch.normalizedCountryCode,
            entity: itunesSearch.entity,
            limit: itunesSearch.clampedLimit,
            lookupFallbackEnabled: itunesSearch.lookupFallbackEnabled
        )
    }
}
