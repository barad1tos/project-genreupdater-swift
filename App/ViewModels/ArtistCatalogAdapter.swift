import Core
import DesignUI
import Services

enum ArtistCatalogAdapter {
    static func makeScope(
        selected: [String],
        projection: ArtistCatalogProjection
    ) -> DesignArtistScope {
        let options: [DesignArtistOption]
        let issue: String?

        switch projection.state {
        case let .available(entries):
            options = entries.map { DesignArtistOption(name: $0.name, trackCount: $0.trackCount) }
            issue = nil
        case let .unavailable(reason):
            options = []
            issue = reason
        }

        return DesignArtistScope(
            selected: ArtistAllowList.normalized(selected),
            options: options,
            catalogIssue: issue
        )
    }
}

extension AppDependencies {
    func refreshArtistCatalog() async -> ArtistCatalogProjection {
        let generation = await projectionStore.claimArtistCatalogGeneration()
        let projection: ArtistCatalogProjection

        guard let trackStore else {
            projection = .init(
                revision: .initial,
                state: .unavailable(reason: "Artist catalog isn’t ready yet.")
            )
            return await projectionStore.replaceArtistCatalog(projection, inputGeneration: generation)
        }

        do {
            projection = try await ArtistCatalogBuilder.makeProjection(tracks: trackStore.loadAllTracks())
        } catch {
            projection = .init(
                revision: .initial,
                state: .unavailable(reason: "Couldn’t load artists from the library mirror.")
            )
        }

        return await projectionStore.replaceArtistCatalog(projection, inputGeneration: generation)
    }
}
