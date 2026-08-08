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

    /// Claim the generation BEFORE the input's long awaits: the track
    /// facts are already snapshotted in the caller's argument, so claim
    /// order equals fact-snapshot order and a slow older refresh can
    /// never out-claim a newer one.
    func claimBrowseInputGeneration() async -> UInt64 {
        await projectionStore.nextBrowseInputGeneration()
    }

    /// Publishes an already-built projection so callers pay one build
    /// per refresh and can compare content against the stored result.
    @discardableResult
    func publishBrowseProjection(_ projection: BrowseProjection, inputGeneration: UInt64) async -> BrowseProjection {
        await projectionStore.replaceBrowseProjection(projection, inputGeneration: inputGeneration)
    }

    /// One browse refresh for one load: claim BEFORE the input's awaits
    /// (the track facts are already snapshotted in the argument, so
    /// claim order equals fact-snapshot order), re-check validity after
    /// every await, and pair the row index only with a projection this
    /// input actually produced. Returns nil when the load was
    /// superseded; rowIndex is nil when another claimant's content won.
    func refreshBrowseProjection(
        tracks: [Track],
        readSource: BrowseReadSource,
        isCurrent: () -> Bool = { true }
    ) async -> (projection: BrowseProjection, rowIndex: [String: [BrowseTrackRow]]?)? {
        let generation = await claimBrowseInputGeneration()
        let input = await makeBrowseInput(tracks: tracks, readSource: readSource)
        guard isCurrent() else { return nil }
        let built = BrowseBuilder.makeProjection(input: input)
        let published = await publishBrowseProjection(built, inputGeneration: generation)
        guard isCurrent() else { return nil }
        let landed = browseContentMatches(published, built: built)
        return (published, landed ? BrowseBuilder.makeTrackRowIndex(input: input) : nil)
    }

    /// Whether the stored projection is the one an input produced —
    /// everything but the store-owned revision.
    private func browseContentMatches(_ published: BrowseProjection, built: BrowseProjection) -> Bool {
        published.artists == built.artists
            && published.scope == built.scope
            && published.physicalTrackCount == built.physicalTrackCount
            && published.readSource == built.readSource
            && published.operationalIssues == built.operationalIssues
    }

    /// The revalidating browse dispatcher with production wiring: reads
    /// CURRENT store truth and submits through the preview-only path.
    /// A factory so the wiring itself is pinnable (no browse action may
    /// ever reach a write-capable submission).
    func makeBrowseCommands(republish: @escaping @Sendable () async -> Void) -> BrowseCommands {
        BrowseCommands(
            currentBrowse: { [projectionStore] in await projectionStore.currentBrowse() },
            submitAlbumPreview: { [weak self] target in
                guard let self else { throw AppDependencyServiceError.runOrchestratorUnavailable }
                return try await self.submitPreviewRun(albumTarget: target)
            },
            republishBrowse: republish
        )
    }
}
