import Core
import Foundation
import Services

enum FixPlanWrite {
    struct Runtime {
        let coordinator: UpdateCoordinator
        let verifier: any MusicAppVerifying
    }

    struct RunnerDependencies {
        let fixPlanStore: any FixPlanStore
        let mapper: TrackIDMapper
        let batchProcessor: BatchProcessor
        let makeRuntime: @Sendable (FixPlanConfig, ProcessingScopeSnapshot) async throws -> Runtime
        let hasRunRecovery: @Sendable () async -> Bool
    }

    enum Failure: LocalizedError {
        case missingPlan(FixPlanID)
        case missingDecision(FixPlanID)
        case staleDecision
        case staleInput
        case noAcceptedItems
        case invalidDecisionItems(FixPlanID)
        case missingWriteTracks(Int)
        case changedWriteTracks(Int)

        var errorDescription: String? {
            switch self {
            case let .missingPlan(planID):
                "Fix plan \(planID.description) is unavailable"
            case let .missingDecision(planID):
                "Review decision is missing for fix plan \(planID.description)"
            case .staleDecision:
                "Review decision changed before write run started"
            case .staleInput:
                "Fix plan input changed before write run started"
            case .noAcceptedItems:
                "Fix plan has no accepted items to write"
            case let .invalidDecisionItems(planID):
                "Review decision items do not match fix plan \(planID.description)"
            case let .missingWriteTracks(count):
                "Could not refresh \(count) reviewed write tracks from Music.app"
            case let .changedWriteTracks(count):
                "\(count) reviewed write track(s) changed identity in Music.app; review a new fix plan"
            }
        }
    }

    static func proposedChanges(
        from plan: FixPlan,
        decision: FixPlanReviewDecision
    ) throws -> [ProposedChange] {
        let verdicts = try itemVerdicts(from: decision, matching: plan)
        return plan.items.map { item in
            ProposedChange(
                id: item.id,
                track: track(from: item),
                changeType: item.changeType,
                oldValue: item.oldValue,
                newValue: item.newValue,
                confidence: item.confidence,
                source: item.source,
                isAccepted: verdicts[item.id] == .accepted,
                albumArtistChange: item.albumArtistChange
            )
        }
    }

    static func acceptedWorkItems(
        in plan: FixPlan,
        decision: FixPlanReviewDecision
    ) -> [RunWorkItem] {
        let acceptedItemIDs = Set(decision.itemDecisions.compactMap { item in
            item.verdict == .accepted ? item.itemID : nil
        })
        return plan.items
            .filter { acceptedItemIDs.contains($0.id) }
            .map(RunWorkItem.init(item:))
    }

    static func makeInput(
        plan: FixPlan,
        decision: FixPlanReviewDecision,
        configuration: RunConfig
    ) throws -> FixPlanWriteInput {
        guard decision.planID == plan.id,
              decision.planRevision == plan.revision,
              configuration.writeAuthority.canWritePlan,
              configuration.scopeID == plan.scope.id,
              configuration.settings == plan.configuration
        else {
            throw Failure.staleInput
        }
        _ = try itemVerdicts(from: decision, matching: plan)
        let workItems = acceptedWorkItems(in: plan, decision: decision)
        guard !workItems.isEmpty else {
            throw Failure.noAcceptedItems
        }
        return FixPlanWriteInput(
            target: FixPlanWriteTarget(
                planID: plan.id,
                planRevision: plan.revision,
                decisionRevision: decision.revision
            ),
            scope: plan.scope,
            configuration: configuration,
            workItems: workItems
        )
    }

    static func requiredFeature(for workItems: [RunWorkItem]) -> AppFeature? {
        workItems.lazy.compactMap(\.change.changeType.requiredWriteFeature).first
    }

    private static func itemVerdicts(
        from decision: FixPlanReviewDecision,
        matching plan: FixPlan
    ) throws -> [UUID: FixPlanItemVerdict] {
        let planItemIDs = Set(plan.items.map(\.id))
        var verdicts: [UUID: FixPlanItemVerdict] = [:]
        for itemDecision in decision.itemDecisions {
            guard planItemIDs.contains(itemDecision.itemID),
                  verdicts[itemDecision.itemID] == nil
            else {
                throw Failure.invalidDecisionItems(plan.id)
            }
            verdicts[itemDecision.itemID] = itemDecision.verdict
        }
        guard verdicts.count == planItemIDs.count else {
            throw Failure.invalidDecisionItems(plan.id)
        }
        return verdicts
    }

    static func prepareWriteIDs(
        for changes: [ProposedChange],
        mapper: TrackIDMapper,
        verifier: any MusicAppVerifying
    ) async throws {
        let log = AppLogger.make(category: "dependencies")
        var targetsByReadID: [String: (
            track: Track,
            identity: FixPlanItemIdentity,
            databaseID: MusicDatabaseTrackID
        )] = [:]
        var unmappedCount = 0
        for change in changes {
            guard let databaseID = change.track.databaseID else {
                // The write still fails fast later via writeID; the log
                // makes the seeding-time skip visible instead of silent.
                unmappedCount += 1
                log.info("""
                Write seeding skipped a change without an AppleScript id: \
                \(change.track.name, privacy: .private) by \(change.track.artist, privacy: .private)
                """)
                continue
            }
            targetsByReadID[change.track.id] = (
                track: change.track,
                identity: FixPlanItemIdentity(
                    readID: change.track.id,
                    appleScriptID: change.track.appleScriptID,
                    artist: change.track.artist,
                    album: change.track.album,
                    trackName: change.track.name,
                    albumArtist: change.track.albumArtist
                ),
                databaseID: databaseID
            )
        }
        if unmappedCount > 0 {
            log.warning("Write seeding skipped \(unmappedCount, privacy: .public) unmapped change(s)")
        }
        guard !targetsByReadID.isEmpty else { return }

        let databaseIDs = Array(Set(targetsByReadID.values.map(\.databaseID)))
        let currentTracks = try await verifier.fetchMetadata(for: databaseIDs)
        var currentTracksByID: [MusicDatabaseTrackID: Track] = [:]
        for track in currentTracks {
            guard let databaseID = track.databaseID else { continue }
            currentTracksByID[databaseID] = track
        }
        let entries = targetsByReadID.values.compactMap { target in
            currentTracksByID[target.databaseID].map { currentTrack in
                (
                    musicKitTrack: target.track,
                    identity: target.identity,
                    appleScriptTrack: currentTrack
                )
            }
        }
        guard entries.count == targetsByReadID.count else {
            throw Failure.missingWriteTracks(targetsByReadID.count - entries.count)
        }
        let changedTrackCount = identityMismatchCount(in: entries)
        guard changedTrackCount == 0 else {
            throw Failure.changedWriteTracks(changedTrackCount)
        }

        await mapper.seedKnownMappings(entries.map { entry in
            (musicKitTrack: entry.musicKitTrack, appleScriptTrack: entry.appleScriptTrack)
        })
    }

    private static func identityMismatchCount(
        in entries: [(musicKitTrack: Track, identity: FixPlanItemIdentity, appleScriptTrack: Track)]
    ) -> Int {
        entries.count { !$0.identity.matchesCurrentTrack($0.appleScriptTrack) }
    }

    static func makeRunner(
        _ dependencies: RunnerDependencies
    ) -> @Sendable (FixPlanWriteInput, RunID, @escaping WorkCheckpointSink) async throws -> BatchUpdateResult {
        { input, runID, checkpoint in
            if await dependencies.hasRunRecovery() {
                throw WriteAdmissionError.recoveryRequired
            }
            // Distinct read identities in the run's work set. No production
            // path builds an album work target, so track targets are the whole
            // write surface.
            let trackCount = Set(input.workItems.compactMap { item -> String? in
                guard case let .track(identity) = item.target else { return nil }
                return identity.readID
            }).count
            return try await dependencies.batchProcessor.performRecoverableWrite(
                trackCount: trackCount,
                requiredFeature: requiredFeature(for: input.workItems),
                requiredAdmissionFeature: input.requiredAdmissionFeature,
                appliedTrackIDs: { Set($0.entries.map(\.trackID)) },
                partialTrackIDs: { _ in [] },
                operation: {
                    guard let plan = try await dependencies.fixPlanStore.plan(
                        id: input.target.planID,
                        revision: input.target.planRevision
                    ) else {
                        throw Failure.missingPlan(input.target.planID)
                    }
                    guard let decision = try await dependencies.fixPlanStore.currentDecision(
                        for: input.target.planID
                    ) else {
                        throw Failure.missingDecision(input.target.planID)
                    }
                    guard decision.planRevision == input.target.planRevision,
                          decision.revision == input.target.decisionRevision
                    else {
                        throw Failure.staleDecision
                    }
                    try validateInput(input, plan: plan, decision: decision)

                    let changes = try proposedChanges(from: plan, decision: decision)
                    let acceptedChanges = changes.filter(\.isAccepted)
                    guard !acceptedChanges.isEmpty else {
                        throw Failure.noAcceptedItems
                    }

                    let runtime = try await dependencies.makeRuntime(plan.configuration, input.scope)
                    try await prepareWriteIDs(
                        for: acceptedChanges,
                        mapper: dependencies.mapper,
                        verifier: runtime.verifier
                    )
                    // The runtime coordinator is created per write; attribution
                    // stays set for its whole lifetime.
                    await runtime.coordinator.setRunAttribution(runID)
                    return try await runtime.coordinator.applyAcceptedChanges(
                        changes,
                        progressHandler: ignoreProgress,
                        checkpoint: checkpoint
                    )
                }
            )
        }
    }

    private static func validateInput(
        _ input: FixPlanWriteInput,
        plan: FixPlan,
        decision: FixPlanReviewDecision
    ) throws {
        // The input crosses an async queue; it must still match the immutable plan revision.
        let expectedWorkItems = acceptedWorkItems(in: plan, decision: decision)
        guard plan.scope == input.scope,
              input.configuration.writeAuthority.canWritePlan,
              input.configuration.scopeID == plan.scope.id,
              input.configuration.settings == plan.configuration,
              input.workItems == expectedWorkItems
        else {
            throw Failure.staleInput
        }
    }

    private static func track(from item: FixPlanItem) -> Track {
        Track(
            id: item.identity.readID,
            name: item.identity.trackName,
            artist: item.identity.artist,
            album: item.identity.album,
            genre: item.changeType == .genreUpdate ? item.oldValue : nil,
            year: item.changeType == .yearUpdate ? year(from: item.oldValue) : nil,
            albumArtist: item.identity.albumArtist,
            appleScriptID: item.identity.appleScriptID
        )
    }

    private static func year(from value: String?) -> Int? {
        value.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func ignoreProgress(_: ProgressUpdate) {
        // Fix-plan writes do not expose intermediate progress.
    }
}

extension AppDependencies {
    /// Housekeeping after a successful run prune: deletes plans no persisted
    /// run references anymore. The newest plan and every in-flight write
    /// target (queued slot, parked pending requests, active run) ride on top
    /// of the run-referenced set; a nil reference set (unreadable payload)
    /// skips deletion entirely. Failures are logged, never thrown — the run
    /// record is already persisted.
    func pruneFixPlans(runRecordStore: any RunRecordStore) async {
        guard let fixPlanStore else { return }
        do {
            guard let retained = try await runRecordStore.retainedPlanIDs() else { return }
            var keeping = retained
            if let currentPlanID = try await fixPlanStore.latestPlan()?.id {
                keeping.insert(currentPlanID)
            }
            if let runOrchestrator {
                await keeping.formUnion(runOrchestrator.inFlightWritePlanIDs())
            }
            _ = try await fixPlanStore.deletePlans(notIn: keeping)
        } catch {
            AppLogger.make(category: "dependencies").error("""
            Fix-plan retention failed with \
            \(String(describing: type(of: error)), privacy: .public): \
            \(error.localizedDescription, privacy: .private)
            """)
        }
    }

    func makeWriteRunner(
        runtime: RunRuntimeFactory?
    ) -> (@Sendable (FixPlanWriteInput, RunID, @escaping WorkCheckpointSink) async throws -> BatchUpdateResult)? {
        guard let runtime,
              let fixPlanStore,
              let mapper = trackIDMapper,
              let batchProcessor
        else {
            AppLogger.make(category: "dependencies")
                .warning("Fix plan writer unavailable: missing write prerequisites")
            assertionFailure("Fix plan writer unavailable: missing write prerequisites")
            return nil
        }
        let hasRunRecovery: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return true }
            return await self.ensureRecoveryHold()
        }

        return FixPlanWrite.makeRunner(FixPlanWrite.RunnerDependencies(
            fixPlanStore: fixPlanStore,
            mapper: mapper,
            batchProcessor: batchProcessor,
            makeRuntime: { configuration, scope in
                try await runtime.makeWrite(configuration: configuration, scope: scope)
            },
            hasRunRecovery: hasRunRecovery
        ))
    }
}
