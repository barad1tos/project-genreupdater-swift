import Core
import Foundation

public struct FixPlanProducer: Sendable {
    public struct Runtime: Sendable {
        public let refreshIdentity: @Sendable ([Track], ProcessingScopeSnapshot) async throws -> Void
        public let albumContext: @Sendable ([Track]) async -> [String: [Track]]
        public let artistContext: @Sendable ([Track]) async -> [String: [Track]]
        /// Determines one track's changes. Forward the run scope unchanged to `UpdateCoordinator.updateTrack`.
        public let determineChanges: @Sendable (Track, [Track], [Track], UpdateOptions, YearRunScope) async throws
            -> [ProposedChange]

        public init(
            refreshIdentity: @escaping @Sendable ([Track], ProcessingScopeSnapshot) async throws -> Void,
            albumContext: @escaping @Sendable ([Track]) async -> [String: [Track]],
            artistContext: @escaping @Sendable ([Track]) async -> [String: [Track]],
            determineChanges: @escaping @Sendable (
                Track,
                [Track],
                [Track],
                UpdateOptions,
                YearRunScope
            ) async throws -> [ProposedChange]
        ) {
            self.refreshIdentity = refreshIdentity
            self.albumContext = albumContext
            self.artistContext = artistContext
            self.determineChanges = determineChanges
        }
    }

    public struct Dependencies: Sendable {
        public let loadTracks: @Sendable () async throws -> [Track]
        public let makeRuntime: @Sendable (FixPlanConfig, ProcessingScopeSnapshot) async throws -> Runtime
        public let savePlan: @Sendable (FixPlan, FixPlanReviewDecision) async throws -> Void
        public let now: @Sendable () -> Date

        public init(
            loadTracks: @escaping @Sendable () async throws -> [Track],
            makeRuntime: @escaping @Sendable (FixPlanConfig, ProcessingScopeSnapshot) async throws -> Runtime,
            savePlan: @escaping @Sendable (FixPlan, FixPlanReviewDecision) async throws -> Void,
            now: @escaping @Sendable () -> Date
        ) {
            self.loadTracks = loadTracks
            self.makeRuntime = makeRuntime
            self.savePlan = savePlan
            self.now = now
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func producePlan(
        sourceRunID: RunID,
        scope: ProcessingScopeSnapshot,
        configuration: FixPlanConfig
    ) async throws -> FixPlanProduction {
        let options = configuration.determinationOptions
        let tracks = try await dependencies.loadTracks()
        let scopedTracks = Self.scopedTracks(tracks, scope: scope)
        let targetedTracks = Self.albumTargetedTracks(scopedTracks, target: configuration.albumTarget)
        guard !targetedTracks.isEmpty else { return .empty }
        let runtime = try await dependencies.makeRuntime(configuration, scope)
        // Artist evidence spans the full scope, so its authoritative grouping
        // metadata must be refreshed even when proposals target one album.
        try await runtime.refreshIdentity(scopedTracks, scope)
        let albumTracksByTrackID = await runtime.albumContext(targetedTracks)
        // Artist context spans the FULL scope: dominant-genre
        // determination must see the artist's other albums, or a
        // targeted preview would propose different metadata than a
        // whole-scope one for the same track.
        let artistTracksByTrackID = await runtime.artistContext(scopedTracks)
        let yearRunScope = YearRunScope()
        let context = PlanContext(
            runtime: runtime,
            albumTracks: albumTracksByTrackID,
            artistTracks: artistTracksByTrackID,
            options: options,
            yearRunScope: yearRunScope
        )
        let proposals = try await determineProposals(
            for: targetedTracks,
            context: context,
            concurrencyLimit: Self.planningConcurrencyLimit(configuration)
        )

        let filteredProposals = ChangePreviewPipeline().filter(
            changes: proposals,
            minConfidence: options.minConfidence
        )
        let producedAt = dependencies.now()
        guard let plan = FixPlanCapture.makePlan(
            from: filteredProposals,
            sourceRunID: sourceRunID,
            scope: scope,
            configuration: configuration,
            createdAt: producedAt
        ) else {
            return .empty
        }

        let decision = FixPlanReviewer.initialDecision(for: plan, at: producedAt)
        try await dependencies.savePlan(plan, decision)
        return FixPlanProduction(planID: plan.id, proposalCount: plan.items.count)
    }

    private func determineProposals(
        for tracks: [Track],
        context: PlanContext,
        concurrencyLimit: Int
    ) async throws -> [ProposedChange] {
        let workUnits = Self.albumWorkUnits(tracks)
        return try await withThrowingTaskGroup(of: (Int, [ProposedChange]).self) { group in
            var nextIndex = 0
            let initialCount = min(concurrencyLimit, workUnits.count)
            while nextIndex < initialCount {
                Self.addAlbumUnit(
                    at: nextIndex,
                    from: workUnits,
                    to: &group,
                    context: context
                )
                nextIndex += 1
            }

            var proposalsByUnit = [[ProposedChange]?](repeating: nil, count: workUnits.count)
            while let (index, proposals) = try await group.next() {
                proposalsByUnit[index] = proposals
                if nextIndex < workUnits.count {
                    Self.addAlbumUnit(
                        at: nextIndex,
                        from: workUnits,
                        to: &group,
                        context: context
                    )
                    nextIndex += 1
                }
            }
            return proposalsByUnit.compactMap(\.self).flatMap(\.self)
        }
    }

    private static func addAlbumUnit(
        at index: Int,
        from workUnits: [[Track]],
        to group: inout ThrowingTaskGroup<(Int, [ProposedChange]), any Error>,
        context: PlanContext
    ) {
        let tracks = workUnits[index]
        group.addTask {
            let proposals = try await determineAlbumProposals(
                for: tracks,
                context: context
            )
            return (index, proposals)
        }
    }

    private static func determineAlbumProposals(
        for tracks: [Track],
        context: PlanContext
    ) async throws -> [ProposedChange] {
        var proposals: [ProposedChange] = []
        for track in tracks {
            try Task.checkCancellation()
            do {
                let changes = try await context.runtime.determineChanges(
                    track,
                    context.albumTracks[track.id] ?? [],
                    context.artistTracks[track.id] ?? [],
                    context.options,
                    context.yearRunScope
                )
                proposals.append(contentsOf: changes)
            } catch let error where isWriteEligibilityError(error) {
                continue
            }
        }
        return proposals
    }

    private static func albumWorkUnits(_ tracks: [Track]) -> [[Track]] {
        var workUnits: [[Track]] = []
        var indicesByAlbum: [String: Int] = [:]
        for track in tracks {
            let albumKey = AlbumIdentity.key(for: track)
            if let index = indicesByAlbum[albumKey] {
                workUnits[index].append(track)
            } else {
                indicesByAlbum[albumKey] = workUnits.count
                workUnits.append([track])
            }
        }
        return workUnits
    }

    private static func planningConcurrencyLimit(_ configuration: FixPlanConfig) -> Int {
        let appConfiguration = configuration.appConfiguration
        var limit = appConfiguration.applescript.concurrency
        if configuration.updateGenre {
            limit = min(limit, appConfiguration.genreUpdate.concurrentLimit)
        }
        if configuration.updateYear {
            limit = min(limit, appConfiguration.yearRetrieval.rateLimits.concurrentAPICalls)
        }
        return limit
    }

    private struct PlanContext: Sendable {
        let runtime: Runtime
        let albumTracks: [String: [Track]]
        let artistTracks: [String: [Track]]
        let options: UpdateOptions
        let yearRunScope: YearRunScope
    }

    private static func scopedTracks(_ tracks: [Track], scope: ProcessingScopeSnapshot) -> [Track] {
        switch scope.source {
        case .fullLibrary:
            tracks
        case .testArtists:
            // A .testArtists snapshot with an empty normalized list cannot
            // come from capture(); a decoded or hand-built one must fail
            // CLOSED — ArtistAllowList.filter's empty-list arm would widen
            // the plan to the whole library on the write path.
            scope.normalizedTestArtists.isEmpty
                ? []
                : ArtistAllowList.filter(tracks, allowedArtists: scope.normalizedTestArtists)
        }
    }

    /// Intersects already-scoped tracks with one album's CANONICAL
    /// identity key — the same key browse nodes are formed under. The
    /// track-side key already absorbs albumArtist grouping and feature
    /// suffixes; the alias-expanded lookup keys exist for legacy cache
    /// lookup where over-matching is benign, and as a selection
    /// predicate they would pull a neighboring node's tracks into the
    /// plan. Target strings are a browse node's display identity. Pure
    /// narrowing: this can only ever shrink the scoped set.
    private static func albumTargetedTracks(_ tracks: [Track], target: FixPlanAlbumTarget?) -> [Track] {
        guard let target else { return tracks }

        let targetKey = AlbumIdentity(artist: target.artist, album: target.album).key
        return tracks.filter { AlbumIdentity(track: $0).key == targetKey }
    }

    private static func isWriteEligibilityError(_ error: any Error) -> Bool {
        switch error {
        case UpdateCoordinatorError.trackNotEditable, UpdateCoordinatorError.missingAppleScriptID:
            true
        default:
            false
        }
    }
}
