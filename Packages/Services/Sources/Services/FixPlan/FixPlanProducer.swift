import Core
import Foundation

public struct FixPlanProducer: Sendable {
    public struct Dependencies: Sendable {
        public let loadTracks: @Sendable () async throws -> [Track]
        public let albumContextTracksByTrackID: @Sendable ([Track]) async -> [String: [Track]]
        public let determineTrackChanges: @Sendable (Track, [Track], [Track], UpdateOptions) async throws
            -> [ProposedChange]
        public let savePlan: @Sendable (FixPlan, FixPlanReviewDecision) async throws -> Void
        public let now: @Sendable () -> Date

        public init(
            loadTracks: @escaping @Sendable () async throws -> [Track],
            albumContextTracksByTrackID: @escaping @Sendable ([Track]) async -> [String: [Track]],
            determineTrackChanges: @escaping @Sendable (
                Track,
                [Track],
                [Track],
                UpdateOptions
            ) async throws -> [ProposedChange],
            savePlan: @escaping @Sendable (FixPlan, FixPlanReviewDecision) async throws -> Void,
            now: @escaping @Sendable () -> Date
        ) {
            self.loadTracks = loadTracks
            self.albumContextTracksByTrackID = albumContextTracksByTrackID
            self.determineTrackChanges = determineTrackChanges
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
        options: UpdateOptions
    ) async throws -> FixPlanProduction {
        let tracks = try await dependencies.loadTracks()
        let scopedTracks = Self.scopedTracks(tracks, scope: scope)
        let albumTracksByTrackID = await dependencies.albumContextTracksByTrackID(scopedTracks)
        let artistGroups = Self.groupTracksByArtist(scopedTracks)

        var proposals: [ProposedChange] = []
        for track in scopedTracks {
            try Task.checkCancellation()
            do {
                let changes = try await dependencies.determineTrackChanges(
                    track,
                    albumTracksByTrackID[track.id] ?? [],
                    artistGroups[Self.artistKey(for: track)] ?? [],
                    options
                )
                proposals.append(contentsOf: changes)
            } catch let error where Self.isWriteEligibilityError(error) {
                continue
            }
        }

        let filteredProposals = ChangePreviewPipeline().filter(
            changes: proposals,
            minConfidence: options.minConfidence
        )
        let producedAt = dependencies.now()
        let configuration = FixPlanConfigurationSnapshot.capture(options: options, capturedAt: producedAt)
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

    private static func scopedTracks(_ tracks: [Track], scope: ProcessingScopeSnapshot) -> [Track] {
        switch scope.source {
        case .fullLibrary:
            tracks
        case .testArtists:
            ArtistAllowList.filter(tracks, allowedArtists: scope.normalizedTestArtists)
        }
    }

    private static func groupTracksByArtist(_ tracks: [Track]) -> [String: [Track]] {
        Dictionary(grouping: tracks) { artistKey(for: $0) }
    }

    private static func artistKey(for track: Track) -> String {
        normalizeForMatching(track.effectiveArtist)
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
