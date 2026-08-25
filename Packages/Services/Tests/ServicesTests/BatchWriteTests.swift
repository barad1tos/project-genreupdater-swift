import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("UpdateCoordinator - batch write verification")
struct BatchWriteTests {
    @Test("A mixed batch keeps a coupled artist rename atomic")
    func coupledArtistRenameBatch() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let input = coupledBatchInput(currentAlbumArtist: "Massive")
        await fixture.bridge.setFetchedTracks([input.currentTrack])

        let result = try await fixture.coordinator.applyAcceptedChanges(
            input.proposals,
            progressHandler: ignoreProgress
        )

        #expect(await fixture.bridge.batchUpdates == [[
            MusicTrackUpdate(databaseID: testDatabaseID("T1"), property: .artist, value: "Massive Attack"),
            MusicTrackUpdate(databaseID: testDatabaseID("T1"), property: .albumArtist, value: "Massive Attack"),
            MusicTrackUpdate(databaseID: testDatabaseID("T1"), property: .genre, value: "Trip-Hop"),
        ]])
        #expect(result.entries.count == 2)
        #expect(result.entries.first?.albumArtistChange?.newValue == "Massive Attack")
    }

    @Test("A mixed batch preserves an album artist changed after review")
    func batchPreservesDistinctAlbumArtist() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let input = coupledBatchInput(currentAlbumArtist: "Various Artists")
        await fixture.bridge.setFetchedTracks([input.currentTrack])
        let checkpoints = CheckpointProbe()

        let result = try await fixture.coordinator.applyAcceptedChanges(
            input.proposals,
            progressHandler: ignoreProgress,
            checkpoint: { await checkpoints.append($0) }
        )

        #expect(await fixture.bridge.batchUpdates == [[
            MusicTrackUpdate(databaseID: testDatabaseID("T1"), property: .artist, value: "Massive Attack"),
            MusicTrackUpdate(databaseID: testDatabaseID("T1"), property: .genre, value: "Trip-Hop"),
        ]])
        #expect(result.entries.first?.albumArtistChange == nil)
        let prepared = await checkpoints.values.first
        #expect(prepared?.writeChanges == [
            input.proposals[0].id: WorkChange(
                changeType: .artistRename,
                oldValue: "Massive",
                newValue: "Massive Attack",
                confidence: 100,
                source: "Artist mappings"
            ),
            input.proposals[1].id: WorkChange(
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Trip-Hop",
                confidence: 90,
                source: "Library"
            ),
        ])
    }

    @Test("A duplicate accepted change ID fails before dispatch")
    func rejectsDuplicateID() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let input = coupledBatchInput(currentAlbumArtist: "Massive")
        let genre = input.proposals[1]
        let duplicate = ProposedChange(
            id: input.proposals[0].id,
            track: genre.track,
            changeType: genre.changeType,
            oldValue: genre.oldValue,
            newValue: genre.newValue,
            confidence: genre.confidence,
            source: genre.source,
            isAccepted: true
        )

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                [input.proposals[0], duplicate],
                progressHandler: ignoreProgress
            )
            Issue.record("Expected duplicate change IDs to be rejected")
        } catch let UpdateCoordinatorError.duplicateChangeID(changeID) {
            #expect(changeID == input.proposals[0].id)
        }

        #expect(await fixture.bridge.batchUpdates.isEmpty)
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("A partial coupled batch is not recorded as a verified rename")
    func partialCoupledBatchIsUnverified() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let input = coupledBatchInput(currentAlbumArtist: "Massive")
        await fixture.bridge.setFetchedTracks([input.currentTrack])
        await fixture.bridge.setBatchMutationLimit(1)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                input.proposals,
                progressHandler: ignoreProgress
            )
        }

        #expect(await fixture.undo.getHistory().isEmpty)

        await fixture.bridge.setBatchMutationLimit(nil)
        let retry = try await fixture.coordinator.applyAcceptedChanges(
            input.proposals,
            progressHandler: ignoreProgress
        )
        let rename = try #require(retry.entries.first { $0.changeType == .artistRename })

        #expect(rename.albumArtistChange?.newValue == "Massive Attack")
        #expect(await fixture.undo.getHistory().contains { $0.id == rename.id })
    }

    @Test("Unavailable batch verification reports an unknown outcome")
    func unknownBatchVerification() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setFetchedTracksClearedAfterBatchUpdate(true)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let track = makeTrack(id: "MK1", databaseID: "AS1", genre: "Rock", year: 1999)
        let observedTrack = makeTrack(id: "observed-AS1", databaseID: "AS1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.bridge.setFetchedTracks([observedTrack])
        let proposals = acceptedProposals(for: track)

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress
            )
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        let databaseID = try #require(MusicDatabaseTrackID(rawValue: "AS1"))
        #expect(batches.count == 1)
        #expect(written.isEmpty)
        #expect(await fixture.bridge.fetchMetadataCalls() == [
            [databaseID],
            [databaseID],
        ])
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    @Test("Direct batch timeout invalidates attempted write caches")
    func directBatchTimeoutClearsCaches() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setCustomBatchError(
            AppleScriptOutcomeError(scriptName: "batch_update_tracks", duration: .seconds(3))
        )
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.cache.setCachedAPIResult(CachedAPIResult(
            artist: track.artist,
            album: track.album,
            year: 1999,
            source: "discogs",
            timestamp: .now,
            ttl: nil
        ))
        await fixture.bridge.setFetchedTracks([track])

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                acceptedProposals(for: track),
                progressHandler: ignoreProgress
            )
        }

        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.cache.getCachedAPIResult(
            artist: track.artist,
            album: track.album,
            source: "discogs"
        ) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    @Test("Generated mapped partial batches report an unknown outcome")
    func mappedPartialBatchIsUnknown() async throws {
        let mapper = TrackIDMapper()
        let musicKitTrack = makeTrack(
            id: "MK1",
            name: "Song (Remastered 2020)",
            genre: nil,
            year: 1999
        )
        let appleScriptTrack = makeTrack(
            id: "AS1",
            name: "Song (Remastered 2020)",
            genre: nil,
            year: 1999
        )
        await mapper.refreshMapping(
            musicKitTracks: [musicKitTrack],
            appleScriptTracks: [appleScriptTrack]
        )
        let fixture = await makeCoordinator(batchUpdatesEnabled: true, idMapper: mapper)
        await fixture.bridge.setBatchMutationLimit(1)
        await fixture.bridge.setFetchedTracks([appleScriptTrack])

        await #expect(throws: AppleScriptOutcomeError.self) {
            _ = try await fixture.coordinator.updateTracks(
                [musicKitTrack],
                options: UpdateOptions(
                    updateGenre: false,
                    updateYear: true,
                    cleanTrackNames: true
                ),
                progressHandler: ignoreProgress
            )
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.databaseID.rawValue) == ["AS1", "AS1"])
        #expect(written.isEmpty)
    }

    @Test("A batch cancellation after admission enters recovery")
    func recoversBatchCancellation() async {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchCancellationMode(true)
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)
        let checkpoints = CheckpointRecorder()
        let records = WriteRecordProbe()
        let recoveryID = UUID()
        let input = writeInput(workItems: workItems(for: proposals))
        let coordinator = fixture.coordinator
        let orchestrator = RunOrchestrator(dependencies: .init(
            synchronizeLibrary: { SyncResult() },
            persistRunRecord: { try await records.append($0) },
            write: .init(
                writeFixPlan: { _, _, checkpoint in
                    try await coordinator.applyAcceptedChanges(
                        proposals,
                        progressHandler: ignoreProgress,
                        checkpoint: {
                            await checkpoints.append($0.boundary)
                            try await checkpoint($0)
                        }
                    )
                },
                beginRecoveryHold: { recoveryID }
            )
        ))

        let result = await orchestrator.submit(.manualWrite(input: input))

        guard case let .recoverable(snapshot, _) = result else {
            Issue.record("Expected recoverable result, got \(result)")
            return
        }

        #expect(await checkpoints.boundaries == [.beforeAttempt])
        #expect(snapshot.workItems.allSatisfy { $0.state == .attempting })
        #expect(await records.records.last?.state == .recoverable)
        #expect(await records.records.last?.recoveryID == recoveryID)
        #expect(await records.records.last?.workItems.allSatisfy { $0.state == .attempting } == true)
        #expect(await fixture.bridge.writtenProperties.isEmpty)
    }

    @Test("A stale reviewed item does not discard a valid batch peer")
    func isolatesStalePeer() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let reviewedTrack = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        let currentTrack = makeTrack(id: "MK1", genre: "Jazz", year: 1999)
        await fixture.bridge.setFetchedTracks([currentTrack])
        let proposals = acceptedProposals(for: reviewedTrack)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.map { $0.map(\.property) } == [[.year]])
        #expect(written.isEmpty)
        #expect(result.entries.map(\.changeType) == [.yearUpdate])
        #expect(result.noOpEntries.isEmpty)
        #expect(result.failedTrackIDs == ["MK1"])
        #expect(result.errorDescriptions.count == 1)
        #expect(result.errorDescriptions.first?.contains("reviewed value no longer matches Music.app") == true)
        #expect(result.hasPartialFailures)
    }

    @Test("Pre-run batch failure falls back to single writes")
    func preRunBatchFailureFallsBackToSingleWrites() async throws {
        try await assertPreRunBatchFailureFallsBack(
            existingGenre: "Rock",
            expectedEntries: [.genreUpdate, .yearUpdate],
            expectedNoOpEntries: []
        )
    }

    @Test("Pre-run batch failure falls back when one value already matches")
    func preRunBatchFailureFallsBackWhenOneValueAlreadyMatches() async throws {
        try await assertPreRunBatchFailureFallsBack(
            existingGenre: "Stoner Rock",
            expectedEntries: [.yearUpdate],
            expectedNoOpEntries: [.genreUpdate]
        )
    }

    private func assertPreRunBatchFailureFallsBack(
        existingGenre: String,
        expectedEntries: [ChangeType],
        expectedNoOpEntries: [ChangeType]
    ) async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchThrowMode(true)
        let track = makeTrack(id: "MK1", genre: existingGenre, year: 1999)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)

        let result = try await fixture.coordinator.applyAcceptedChanges(
            proposals,
            progressHandler: ignoreProgress
        )

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.map(\.property) == [.genre, .year])
        #expect(result.entries.map(\.changeType) == expectedEntries)
        #expect(result.noOpEntries.map(\.changeType) == expectedNoOpEntries)
        #expect(!result.hasPartialFailures)
    }

    @Test("Partial batch verification reports an unknown outcome")
    func partialVerificationIsUnknown() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchMutationLimit(1)
        await fixture.bridge.setSingleWriteResult(.noChange)
        let track = makeTrack(id: "MK1", genre: "Rock", year: 1999)
        await fixture.cache.storeAlbumYear(artist: track.artist, album: track.album, year: 1999, confidence: 80)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = acceptedProposals(for: track)

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress
            )
            Issue.record("Expected a partially applied batch outcome")
        } catch let error as PartialWriteError {
            #expect(error.appliedTrackIDs == [track.id])
            #expect(error.underlyingError is AppleScriptOutcomeError)
        } catch {
            Issue.record("Expected PartialWriteError, got \(error)")
        }

        let batches = await fixture.bridge.batchUpdates
        let written = await fixture.bridge.writtenProperties
        #expect(batches.count == 1)
        #expect(written.isEmpty)
        #expect(await fixture.cache.getAlbumYear(artist: track.artist, album: track.album) == nil)
        #expect(await fixture.snapshot.wasCleared())
    }

    @Test("A partial batch records a verified empty-year write")
    func partialBatchRecordsYearClear() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        await fixture.bridge.setBatchMutationLimit(1)
        let yearTrack = makeTrack(id: "Y1", genre: "Rock", year: 2019)
        await fixture.bridge.setFetchedTracks([yearTrack])
        let proposals = [
            ProposedChange(
                track: yearTrack,
                changeType: .yearRevert,
                oldValue: "2019",
                newValue: String(MusicAppYear.missingValue),
                confidence: 100,
                source: "undo",
                isAccepted: true
            ),
            ProposedChange(
                track: yearTrack,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library",
                isAccepted: true
            ),
        ]

        do {
            _ = try await fixture.coordinator.applyAcceptedChanges(
                proposals,
                progressHandler: ignoreProgress
            )
            Issue.record("Expected a partially applied batch outcome")
        } catch let error as PartialWriteError {
            #expect(error.appliedTrackIDs == [yearTrack.id])
            #expect(error.underlyingError is AppleScriptOutcomeError)
        } catch {
            Issue.record("Expected PartialWriteError, got \(error)")
        }

        let history = await fixture.undo.getHistory()
        #expect(history.map(\.trackID) == [yearTrack.id])
        #expect(history.map(\.changeType) == [.yearRevert])
        #expect(history.first?.newYear == MusicAppYear.missingValue)
    }

    @Test("A generated batch treats an already-empty year clear as a no-op")
    func recognizesEmptyYearClear() async throws {
        let fixture = await makeCoordinator(batchUpdatesEnabled: true)
        let track = makeTrack(id: "Y1", genre: "Rock", year: nil)
        await fixture.bridge.setFetchedTracks([track])
        let proposals = [
            ProposedChange(
                track: track,
                changeType: .yearRevert,
                oldValue: "2019",
                newValue: String(MusicAppYear.missingValue),
                confidence: 100,
                source: "undo",
                isAccepted: true
            ),
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library",
                isAccepted: true
            ),
        ]
        var failedTrackIDs: [String] = []
        var errorDescriptions: [String] = []

        let result = try #require(await fixture.coordinator.applyChangesAsBatchIfPossible(
            proposals,
            isReviewedChange: false,
            failedTrackIDs: &failedTrackIDs,
            errorDescriptions: &errorDescriptions
        ))

        #expect(result.entries.map(\.changeType) == [.genreUpdate])
        #expect(result.noOpEntries.map(\.changeType) == [.yearRevert])
        #expect(failedTrackIDs.isEmpty)
        #expect(errorDescriptions.isEmpty)
    }

    private func makeCoordinator(
        batchUpdatesEnabled: Bool,
        idMapper: (any TrackIDMapping)? = nil
    ) async -> BatchWriteFixture {
        let bridge = MusicAppTestAccess()
        let cache = MockCacheService()
        let snapshot = MockLibrarySnapshotService()
        let undoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchWriteTests-\(UUID().uuidString)")
        let undo = UndoCoordinator(musicApp: bridge, directory: undoDir)
        let apiService = MockAPIService(yearResult: YearResult(
            year: 2001,
            confidence: 95,
            yearScores: [2001: 95]
        ))
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: apiService,
                    discogs: apiService,
                    appleMusic: apiService
                ),
                writer: bridge,
                stores: .init(trackStore: MockTrackStore(), cache: cache),
                undoCoordinator: undo,
                idMapper: idMapper,
                librarySnapshotService: snapshot
            ),
            genreDeterminator: GenreDeterminator(),
            runtimeConfiguration: UpdateRuntimeConfiguration(
                areBatchUpdatesEnabled: batchUpdatesEnabled,
                maxBatchUpdateSize: 5
            )
        )
        return BatchWriteFixture(
            coordinator: coordinator,
            bridge: bridge,
            cache: cache,
            snapshot: snapshot,
            undo: undo
        )
    }

    private func coupledBatchInput(
        currentAlbumArtist: String
    ) -> (currentTrack: Track, proposals: [ProposedChange]) {
        let currentTrack = Track(
            id: "T1",
            name: "Teardrop",
            artist: "Massive",
            album: "Mezzanine",
            genre: "Rock",
            trackStatus: TrackKind.subscription.rawValue,
            albumArtist: currentAlbumArtist,
            appleScriptID: "T1"
        )
        let reviewedTrack = Track(
            id: currentTrack.id,
            name: currentTrack.name,
            artist: "Massive Attack",
            album: currentTrack.album,
            genre: currentTrack.genre,
            trackStatus: currentTrack.trackStatus,
            albumArtist: "Massive Attack",
            appleScriptID: currentTrack.appleScriptID
        )
        return (currentTrack, [
            ProposedChange(
                track: reviewedTrack,
                changeType: .artistRename,
                oldValue: "Massive",
                newValue: "Massive Attack",
                confidence: 100,
                source: "Artist mappings",
                isAccepted: true,
                albumArtistChange: AlbumArtistChange(
                    oldValue: "Massive",
                    newValue: "Massive Attack"
                )
            ),
            ProposedChange(
                track: reviewedTrack,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Trip-Hop",
                confidence: 90,
                source: "Library",
                isAccepted: true
            ),
        ])
    }

    private func acceptedProposals(for track: Track) -> [ProposedChange] {
        [
            ProposedChange(
                track: track,
                changeType: .genreUpdate,
                oldValue: "Rock",
                newValue: "Stoner Rock",
                confidence: 90,
                source: "Library",
                isAccepted: true
            ),
            ProposedChange(
                track: track,
                changeType: .yearUpdate,
                oldValue: "1999",
                newValue: "2001",
                confidence: 95,
                source: "MusicBrainz",
                isAccepted: true
            ),
        ]
    }

    private func workItems(for proposals: [ProposedChange]) -> [RunWorkItem] {
        proposals.map { proposal in
            RunWorkItem(
                id: proposal.id,
                target: .track(FixPlanItemIdentity(
                    readID: proposal.track.id,
                    appleScriptID: proposal.track.appleScriptID,
                    artist: proposal.track.artist,
                    album: proposal.track.album,
                    trackName: proposal.track.name
                )),
                change: WorkChange(
                    changeType: proposal.changeType,
                    oldValue: proposal.oldValue,
                    newValue: proposal.newValue,
                    confidence: proposal.confidence,
                    source: proposal.source
                )
            )
        }
    }

    private func makeTrack(
        id: String,
        databaseID: String? = nil,
        name: String = "Come Together",
        genre: String?,
        year: Int?
    ) -> Track {
        Track(
            id: id,
            name: name,
            artist: "Beatles",
            album: "Abbey Road",
            genre: genre,
            year: year,
            trackStatus: TrackKind.subscription.rawValue,
            appleScriptID: databaseID ?? id
        )
    }
}

private func ignoreProgress(_ update: ProgressUpdate) {
    _ = update
}

private struct BatchWriteFixture {
    let coordinator: UpdateCoordinator
    let bridge: MusicAppTestAccess
    let cache: MockCacheService
    let snapshot: MockLibrarySnapshotService
    let undo: UndoCoordinator
}

private actor CheckpointRecorder {
    private(set) var boundaries: [CheckpointBoundary] = []

    func append(_ boundary: CheckpointBoundary) {
        boundaries.append(boundary)
    }
}
