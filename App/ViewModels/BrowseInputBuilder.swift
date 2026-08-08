import Core
import Foundation
import Services

/// Snapshots the probed facts browse assembly needs and publishes the
/// projection through the store (ADR 0013). Publish points live at the
/// host's track-landing sites until slice 10 moves assembly behind the
/// backend.
extension AppDependencies {
    /// The immutable scope browse truth is computed against (ADR 0020).
    /// Recaptured only when Test Artists change, so identical inputs
    /// keep an identical snapshot ID and the store's dedup holds.
    func currentBrowseScopeSnapshot() -> ProcessingScopeSnapshot {
        let normalized = ArtistAllowList.normalized(config.development.testArtists)
        if let cached = cachedBrowseScopeSnapshot, cached.normalizedTestArtists == normalized {
            return cached
        }

        let fresh = ProcessingScopeSnapshot.capture(
            requestedTestArtists: config.development.testArtists,
            knownTrackCount: nil,
            createdAt: Date(),
            reason: "browseProjectionRefresh"
        )
        cachedBrowseScopeSnapshot = fresh
        return fresh
    }

    func makeBrowseInput(tracks: [Track], readSource: BrowseReadSource) async -> BrowseInput {
        // Synchronous MainActor facts first, so the snapshot cannot tear
        // across the await below.
        let scope = currentBrowseScopeSnapshot()
        let previewUnavailableReason = isManualRunAvailable ? nil : "Services are still starting."
        return await BrowseInput(
            tracks: tracks,
            scope: scope,
            physicalTrackCount: probedPhysicalTrackCount(),
            readSource: readSource,
            previewUnavailableReason: previewUnavailableReason
        )
    }

    /// Publishes browse truth built from an input. Snapshot before the
    /// generation claim (the settings-slot precedent): an older claimant
    /// must never carry fresher facts.
    @discardableResult
    func publishBrowseProjection(input: BrowseInput) async -> BrowseProjection {
        let projection = BrowseBuilder.makeProjection(input: input)
        let generation = await projectionStore.nextBrowseInputGeneration()
        return await projectionStore.replaceBrowseProjection(projection, inputGeneration: generation)
    }
}
