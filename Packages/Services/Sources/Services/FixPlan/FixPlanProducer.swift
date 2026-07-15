import Core
import Foundation

public struct FixPlanProducer: Sendable {
    public struct Runtime: Sendable {
        public let refreshIdentity: @Sendable ([Track], ProcessingScopeSnapshot) async throws -> Void
        public let albumContext: @Sendable ([Track]) async -> [String: [Track]]
        public let determineChanges: @Sendable (Track, [Track], [Track], UpdateOptions) async throws
            -> [ProposedChange]

        public init(
            refreshIdentity: @escaping @Sendable ([Track], ProcessingScopeSnapshot) async throws -> Void,
            albumContext: @escaping @Sendable ([Track]) async -> [String: [Track]],
            determineChanges: @escaping @Sendable (
                Track,
                [Track],
                [Track],
                UpdateOptions
            ) async throws -> [ProposedChange]
        ) {
            self.refreshIdentity = refreshIdentity
            self.albumContext = albumContext
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
        guard !scopedTracks.isEmpty else { return .empty }
        let runtime = try await dependencies.makeRuntime(configuration, scope)
        try await runtime.refreshIdentity(scopedTracks, scope)
        let albumTracksByTrackID = await runtime.albumContext(scopedTracks)
        let artistGroups = Self.groupTracksByArtist(scopedTracks)

        var proposals: [ProposedChange] = []
        for track in scopedTracks {
            try Task.checkCancellation()
            do {
                let changes = try await runtime.determineChanges(
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
