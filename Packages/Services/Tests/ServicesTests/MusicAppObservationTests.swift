import Core
import Foundation
import Testing
@testable import Services

@Suite("Music.app observation")
struct MusicAppObservationTests {
    @Test("Mirror rejects a MusicKit ID under an AppleScript database key")
    func rejectsMusicKitID() throws {
        let databaseID = try databaseID("1")
        let musicKitTrack = track(id: databaseID, artist: "Artist", musicKitID: "music-kit-1")

        #expect(LibraryMirrorIndex(tracksByID: [databaseID: musicKitTrack]) == nil)
    }

    @Test("Fast observation fetches only IDs absent from the previous mirror")
    func fetchesOnlyNewMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let firstTrack = track(id: firstID, artist: "Existing Artist")
        let secondTrack = track(id: secondID, artist: "New Artist")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [secondID: secondTrack]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(
            tracksByID: [firstID: firstTrack]
        ))

        let observation = try await reader.observe(request(
            refresh: .fast,
            previous: .verified(mirror)
        ))

        #expect(await source.scopedMetadataRequestIDs == [[secondID]])
        #expect(observation.currentIDs == [firstID, secondID])
        #expect(observation.tracks.map(\.databaseID) == [secondID])
        #expect(observation.membership == .full)
        #expect(observation.metadata.requestedIDs == [secondID])
        #expect(observation.metadata.observedIDs == [secondID])
    }

    @Test("Forced observation refreshes common IDs through the configured source")
    func refreshesCommonMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let firstTrack = track(id: firstID, artist: "Existing Artist")
        let secondTrack = track(id: secondID, artist: "New Artist")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [firstID: firstTrack, secondID: secondTrack]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(
            tracksByID: [firstID: firstTrack]
        ))

        let observation = try await reader.observe(request(
            refresh: .force,
            previous: .verified(mirror)
        ))

        #expect(await source.scopedMetadataRequestIDs == [[firstID, secondID]])
        #expect(observation.tracks.map(\.databaseID) == [firstID, secondID])
        #expect(observation.metadata.isComplete)
    }

    @Test("Membership-only observation fences IDs without fetching metadata")
    func observesMembershipWithoutMetadata() async throws {
        let retainedID = try databaseID("1")
        let removedID = try databaseID("2")
        let newID = try databaseID("3")
        let generation = try libraryGeneration("G1")
        let retainedTrack = track(id: retainedID, artist: "Target")
        let removedTrack = track(id: removedID, artist: "Target")
        let source = try ObservationSourceStub(
            censuses: [census([retainedID, newID], generation: generation)],
            identities: [
                retainedID: identity(id: retainedID, artist: "Target"),
                newID: identity(id: newID, artist: "Target"),
            ],
            tracks: [newID: track(id: newID, artist: "Target")]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(tracksByID: [
            retainedID: retainedTrack,
            removedID: removedTrack,
        ]))
        let inventory = try #require(LibraryInventoryIndex(identitiesByID: [
            retainedID: MemberIdentity(
                databaseID: retainedID,
                artist: "Target",
                albumArtist: nil,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ]))

        let observation = try await reader.observe(request(
            artists: ["Target"],
            refresh: .membershipOnly,
            previous: .verified(mirror),
            inventory: inventory
        ))

        #expect(await source.identitySnapshotRequestCount == 1)
        #expect(await source.scopedMetadataRequests.isEmpty)
        #expect(observation.currentIDs == [retainedID, newID])
        #expect(observation.tracks.isEmpty)
        #expect(observation.membership == .scoped(unobservedIDs: []))
        #expect(observation.metadata.requestedIDs.isEmpty)
        #expect(observation.metadata.observedIDs.isEmpty)
    }

    @Test("Partial metadata keeps complete membership and reports unobserved rows")
    func reportsPartialMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [firstID: track(id: firstID, artist: "Observed Artist")]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request())

        #expect(observation.currentIDs == [firstID, secondID])
        #expect(observation.membership == .full)
        #expect(observation.metadata.requestedIDs == [firstID, secondID])
        #expect(observation.metadata.observedIDs == [firstID])
        #expect(!observation.metadata.isComplete)
        #expect(observation.issues == [
            .metadataUnobserved(databaseID: secondID, detail: "Metadata lookup returned no row"),
        ])
    }

    @Test("Artist scope admits either primary artist or album artist")
    func appliesEitherArtistScope() async throws {
        let albumArtistID = try databaseID("1")
        let fallbackID = try databaseID("2")
        let excludedID = try databaseID("3")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([albumArtistID, fallbackID, excludedID], generation: generation)],
            tracks: [
                albumArtistID: track(id: albumArtistID, artist: "Other", albumArtist: "Target"),
                fallbackID: track(id: fallbackID, artist: "Target", albumArtist: nil),
                excludedID: track(id: excludedID, artist: "Target", albumArtist: "Other"),
            ]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request(artists: ["Target"]))

        #expect(observation.currentIDs == [albumArtistID, fallbackID, excludedID])
        #expect(observation.tracks.map(\.databaseID) == [albumArtistID, fallbackID, excludedID])
        #expect(observation.membership == .scoped(unobservedIDs: []))
        #expect(observation.tracks[1].albumArtist == .absent)
    }

    @Test("Scoped service accepts full-census metadata from the real observer")
    func scopedServiceAcceptsObserverCompleteness() async throws {
        let targetID = try databaseID("1")
        let outsideID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([targetID, outsideID], generation: generation)],
            tracks: [
                targetID: track(id: targetID, artist: "Target"),
                outsideID: track(id: outsideID, artist: "Other"),
            ]
        )
        let observer = MusicAppObserver(source: source)
        let store = SyncMockTrackStore()
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Target"]),
            observer: observer
        )

        let result = try await service.detectObservation().result

        #expect(await source.scopedMetadataRequestIDs == [[targetID]])
        #expect(result.newTracks.map(\.id) == ["1"])
    }

    @Test("Test Artists classifies unknown members before scoped metadata lookup")
    func classifiesUnknownMembersBeforeMetadata() async throws {
        let targetID = try databaseID("1")
        let outsideID = try databaseID("2")
        let knownOutsideID = try databaseID("3")
        let generation = try libraryGeneration("G1")
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let knownOutside = MemberIdentity(
            databaseID: knownOutsideID,
            artist: "Other",
            albumArtist: nil,
            observedAt: observedAt
        )
        let source = try ObservationSourceStub(
            censuses: [census([targetID, outsideID, knownOutsideID], generation: generation)],
            identities: [
                targetID: identity(id: targetID, artist: "Target"),
                outsideID: identity(id: outsideID, artist: "Other"),
                knownOutsideID: identity(id: knownOutsideID, artist: "Other"),
            ],
            tracks: [targetID: track(id: targetID, artist: "Target")]
        )
        let reader = MusicAppObserver(source: source)

        let inventory = try #require(LibraryInventoryIndex(identitiesByID: [knownOutsideID: knownOutside]))
        let observation = try await reader.observe(request(
            artists: ["Target"],
            inventory: inventory
        ))

        #expect(await source.censusRequestCount == 2)
        #expect(await source.identitySnapshotRequestCount == 1)
        let scopedMetadataRequests = await source.scopedMetadataRequests
        #expect(scopedMetadataRequests.count == 1)
        #expect(scopedMetadataRequests.first?.databaseIDs == [targetID])
        #expect(scopedMetadataRequests.first?.scope.source == .testArtists)
        #expect(observation.currentIDs == [targetID])
        #expect(observation.identities.map(\.databaseID) == [targetID, outsideID])
        #expect(observation.identity.isComplete)
        #expect(observation.metadata.isComplete)
    }

    @Test("Unchanged Test Artists fast observation reuses out-of-scope classification")
    func reusesPersistedClassification() async throws {
        let targetID = try databaseID("1")
        let outsideID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let targetTrack = track(id: targetID, artist: "Target")
        let source = try ObservationSourceStub(
            censuses: [census([targetID, outsideID], generation: generation)]
        )
        let reader = MusicAppObserver(source: source)
        let mirror = try #require(LibraryMirrorIndex(tracksByID: [targetID: targetTrack]))
        let inventory = try #require(LibraryInventoryIndex(identitiesByID: [
            targetID: MemberIdentity(
                databaseID: targetID,
                artist: "Target",
                albumArtist: nil,
                observedAt: observedAt
            ),
            outsideID: MemberIdentity(
                databaseID: outsideID,
                artist: "Other",
                albumArtist: nil,
                observedAt: observedAt
            ),
        ]))

        let observation = try await reader.observe(request(
            artists: ["Target"],
            previous: .verified(mirror),
            inventory: inventory
        ))

        #expect(await source.censusRequestCount == 2)
        #expect(await source.identitySnapshotRequestCount == 0)
        #expect(await source.scopedMetadataRequests.isEmpty)
        #expect(observation.currentIDs == [targetID])
        #expect(observation.tracks.isEmpty)
        #expect(observation.identity.requestedIDs.isEmpty)
        #expect(observation.metadata.requestedIDs.isEmpty)
    }

    @Test("Persisted Test Artists inventory makes the second sync request-free")
    func persistsClassificationForWarmSync() async throws {
        let targetID = try databaseID("1")
        let outsideID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([targetID, outsideID], generation: generation)],
            identities: [
                targetID: identity(id: targetID, artist: "Target"),
                outsideID: identity(id: outsideID, artist: "Other"),
            ],
            tracks: [targetID: track(id: targetID, artist: "Target")]
        )
        let store = try TrackDataStore.createInMemory()
        let configuration = LibrarySyncRuntimeConfiguration(testArtists: ["Target"])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: configuration,
            observer: MusicAppObserver(source: source)
        )

        let firstResult = try await service.synchronizeNow()
        let secondResult = try await service.synchronizeNow()
        let snapshot = try await store.loadMirrorSnapshot()
        let certificate = try #require(snapshot.certificates.first)

        #expect(firstResult.newTracks.map(\.id) == ["1"])
        #expect(!secondResult.hasChanges)
        #expect(await source.identitySnapshotRequestCount == 1)
        #expect(await source.scopedMetadataRequestIDs == [[targetID]])
        #expect(Set(snapshot.memberIdentities.keys) == [targetID, outsideID])
        #expect(snapshot.presentTracks.map(\.id) == ["1"])
        #expect(snapshot.readiness(for: configuration.processingRequirement) == .ready(certificate))
    }

    @Test("Swift converges with the Python ID delta and artist-or-album-artist scope")
    func matchesPythonScopedDelta() async throws {
        let retainedID = try databaseID("1")
        let removedID = try databaseID("2")
        let newID = try databaseID("3")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([retainedID, removedID], generation: generation)],
            identities: [
                retainedID: identity(id: retainedID, artist: "Target"),
                removedID: identity(id: removedID, artist: "Other"),
            ],
            tracks: [retainedID: track(id: retainedID, artist: "Target")]
        )
        let store = try TrackDataStore.createInMemory()
        let configuration = LibrarySyncRuntimeConfiguration(testArtists: ["Target"])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: configuration,
            observer: MusicAppObserver(source: source)
        )
        _ = try await service.synchronizeNow()
        try await source.replaceCensus(census([retainedID, newID], generation: generation))
        await source.replaceLibrary(
            identities: [
                retainedID: identity(id: retainedID, artist: "Target"),
                newID: identity(id: newID, artist: "Other", albumArtist: "Target"),
            ],
            tracks: [
                retainedID: track(id: retainedID, artist: "Target"),
                newID: track(id: newID, artist: "Other", albumArtist: "Target"),
            ]
        )

        let result = try await service.synchronizeNow()
        let snapshot = try await store.loadMirrorSnapshot()
        let admission = snapshot.admission(for: configuration.processingRequirement)

        #expect(result.newTracks.map(\.id) == ["3"])
        #expect(result.removedTrackIDs == ["2"])
        #expect(await source.identitySnapshotRequestCount == 2)
        #expect(await source.scopedMetadataRequestIDs == [[retainedID], [newID]])
        guard case let .admitted(mirror) = admission else {
            Issue.record("Expected the Python-matched scoped delta to be admitted")
            return
        }
        #expect(mirror.tracks.map(\.id) == ["1", "3"])
    }

    @Test("Forced identity refresh removes a track from Test Artists without refreshing stale metadata")
    func identityRefreshMovesTrackOutOfScope() async throws {
        let databaseID = try databaseID("1")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([databaseID], generation: generation)],
            identities: [databaseID: identity(id: databaseID, artist: "Target")],
            tracks: [databaseID: track(id: databaseID, artist: "Target")]
        )
        let store = try TrackDataStore.createInMemory()
        let configuration = LibrarySyncRuntimeConfiguration(testArtists: ["Target"])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: configuration,
            observer: MusicAppObserver(source: source)
        )
        _ = try await service.synchronizeNow()
        await source.replaceLibrary(
            identities: [databaseID: identity(id: databaseID, artist: "Other")],
            tracks: [databaseID: track(id: databaseID, artist: "Other")]
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        let snapshot = try await store.loadMirrorSnapshot()
        let admission = snapshot.admission(for: configuration.processingRequirement)

        #expect(await source.identitySnapshotRequestCount == 2)
        #expect(await source.scopedMetadataRequestIDs == [[databaseID]])
        #expect(snapshot.memberIdentities[databaseID]?.artist == "Other")
        #expect(snapshot.presentTracks.first?.artist == "Target")
        guard case let .admitted(mirror) = admission else {
            Issue.record("Expected an admitted empty Test Artists mirror")
            return
        }
        #expect(mirror.tracks.isEmpty)
    }

    @Test("Forced identity refresh admits a track entering Test Artists before metadata lookup")
    func identityRefreshMovesTrackIntoScope() async throws {
        let databaseID = try databaseID("1")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([databaseID], generation: generation)],
            identities: [databaseID: identity(id: databaseID, artist: "Other")],
            tracks: [databaseID: track(id: databaseID, artist: "Other")]
        )
        let store = try TrackDataStore.createInMemory()
        let configuration = LibrarySyncRuntimeConfiguration(testArtists: ["Target"])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: configuration,
            observer: MusicAppObserver(source: source)
        )
        _ = try await service.synchronizeNow()
        let targetTrack = track(id: databaseID, artist: "Target")
        await source.replaceLibrary(
            identities: [databaseID: identity(id: databaseID, artist: "Target")],
            tracks: [databaseID: targetTrack]
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        let snapshot = try await store.loadMirrorSnapshot()
        let admission = snapshot.admission(for: configuration.processingRequirement)

        #expect(await source.identitySnapshotRequestCount == 2)
        #expect(await source.scopedMetadataRequestIDs == [[databaseID]])
        #expect(snapshot.memberIdentities[databaseID]?.artist == "Target")
        guard case let .admitted(mirror) = admission else {
            Issue.record("Expected an admitted Test Artists mirror")
            return
        }
        #expect(mirror.tracks.count == 1)
        #expect(mirror.tracks.first?.databaseID == targetTrack.databaseID)
        #expect(mirror.tracks.first?.artist == "Target")
    }

    @Test("Incomplete identity snapshot fails before mirror mutation")
    func incompleteIdentitySnapshotFailsClosed() async throws {
        let targetID = try databaseID("1")
        let missingID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([targetID, missingID], generation: generation)],
            identities: [targetID: identity(id: targetID, artist: "Target")],
            tracks: [targetID: track(id: targetID, artist: "Target")]
        )
        let store = try TrackDataStore.createInMemory()
        let configuration = LibrarySyncRuntimeConfiguration(testArtists: ["Target"])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: configuration,
            observer: MusicAppObserver(source: source)
        )

        do {
            _ = try await service.synchronizeNow()
            Issue.record("Expected an incomplete identity snapshot to fail")
        } catch MusicAppObservationError.identitySnapshotMismatch {
            // Expected: a producer snapshot must cover its complete census.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let snapshot = try await store.loadMirrorSnapshot()

        #expect(snapshot.presentIDs.isEmpty)
        #expect(snapshot.memberIdentities.isEmpty)
        #expect(snapshot.certificates.isEmpty)
    }

    @Test("Duplicate identity rows reject the observation boundary")
    func rejectsDuplicateIdentityRows() async throws {
        let databaseID = try databaseID("1")
        let generation = try libraryGeneration("G1")
        let duplicate = identity(id: databaseID, artist: "Target")
        let source = try ObservationSourceStub(
            censuses: [census([databaseID], generation: generation)],
            identityResponse: [duplicate, duplicate]
        )

        do {
            _ = try await MusicAppObserver(source: source).observe(request(artists: ["Target"]))
            Issue.record("Expected duplicate identity rows to reject the observation")
        } catch let MusicAppObservationError.duplicateIdentity(rejectedID) {
            #expect(rejectedID == databaseID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An identity row outside the request rejects the observation boundary")
    func rejectsUnexpectedIdentityRow() async throws {
        let requestedID = try databaseID("1")
        let unexpectedID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([requestedID], generation: generation)],
            identityResponse: [identity(id: unexpectedID, artist: "Target")]
        )

        do {
            _ = try await MusicAppObserver(source: source).observe(request(artists: ["Target"]))
            Issue.record("Expected an unexpected identity row to reject the observation")
        } catch let MusicAppObservationError.unexpectedIdentity(rejectedID) {
            #expect(rejectedID == unexpectedID)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Full library derives member identity from required metadata")
    func fullLibraryDerivesIdentityFromMetadata() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([firstID, secondID], generation: generation)],
            tracks: [
                firstID: track(id: firstID, artist: "First"),
                secondID: track(id: secondID, artist: "Second", albumArtist: "Second Album Artist"),
            ]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request())

        #expect(await source.identitySnapshotRequestCount == 0)
        #expect(await source.scopedMetadataRequestIDs == [[firstID, secondID]])
        #expect(observation.identities.map(\.databaseID) == [firstID, secondID])
        #expect(observation.identity.requestedIDs == [firstID, secondID])
        #expect(observation.identity.observedIDs == [firstID, secondID])
    }

    @Test("Scoped force sync preserves a census-present row that exits its artist scope")
    func scopedSyncPreservesScopeExit() async throws {
        let databaseID = try databaseID("1")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([databaseID], generation: generation)],
            tracks: [databaseID: track(id: databaseID, artist: "Other")]
        )
        let observer = MusicAppObserver(source: source)
        let store = SyncMockTrackStore()
        await store.setStored([Track(
            id: "1",
            name: "Song 1",
            artist: "Target",
            album: "Album",
            appleScriptID: "1"
        )])
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: LibrarySyncRuntimeConfiguration(testArtists: ["Target"]),
            observer: observer
        )

        let result = try await service.synchronizeNow(forceMetadataRefresh: true)

        #expect(await source.scopedMetadataRequests.isEmpty)
        #expect(result.removedTrackIDs.isEmpty)
        #expect(await store.storedTracks.map(\.id) == ["1"])
    }

    @Test("Stable empty census is a valid full observation")
    func acceptsStableEmptyCensus() async throws {
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [census([], generation: generation)],
            tracks: [:]
        )
        let reader = MusicAppObserver(source: source)

        let observation = try await reader.observe(request())

        #expect(observation.currentIDs.isEmpty)
        #expect(observation.tracks.isEmpty)
        #expect(observation.membership == .full)
        #expect(observation.metadata.isComplete)
        #expect(await source.scopedMetadataRequests.isEmpty)
    }

    @Test("Generation change after metadata prevents an observation result")
    func rejectsGenerationChange() async throws {
        let databaseID = try databaseID("1")
        let firstGeneration = try libraryGeneration("G1")
        let secondGeneration = try libraryGeneration("G2")
        let source = try ObservationSourceStub(
            censuses: [
                census([databaseID], generation: firstGeneration),
                census([databaseID], generation: secondGeneration),
            ],
            tracks: [databaseID: track(id: databaseID, artist: "Artist")]
        )
        let reader = MusicAppObserver(source: source)

        do {
            _ = try await reader.observe(request())
            Issue.record("Expected generation change to reject the observation")
        } catch let MusicAppObservationError.generationChanged(started, ended) {
            #expect(started == firstGeneration)
            #expect(ended == secondGeneration)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Census membership change rejects an observation even when generation is unchanged")
    func rejectsChangedCensus() async throws {
        let firstID = try databaseID("1")
        let secondID = try databaseID("2")
        let generation = try libraryGeneration("G1")
        let source = try ObservationSourceStub(
            censuses: [
                census([firstID], generation: generation),
                census([firstID, secondID], generation: generation),
            ],
            tracks: [firstID: track(id: firstID, artist: "Artist")]
        )
        let reader = MusicAppObserver(source: source)

        do {
            _ = try await reader.observe(request())
            Issue.record("Expected census change to reject the observation")
        } catch MusicAppObservationError.censusChanged {
            // Expected: generation alone cannot make changed membership atomic.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Census failure is not converted into an empty observation")
    func preservesCensusFailure() async throws {
        let source = ObservationSourceStub(censusError: ObservationTestError.censusFailed)
        let reader = MusicAppObserver(source: source)

        await #expect(throws: ObservationTestError.censusFailed) {
            _ = try await reader.observe(request())
        }
        #expect(await source.scopedMetadataRequests.isEmpty)
    }

    private func request(
        artists: [String] = [],
        refresh: MetadataRefreshPolicy = .fast,
        previous: LibraryMirrorReference = .initial,
        inventory: LibraryInventoryIndex = .empty
    ) -> LibraryObservationRequest {
        LibraryObservationRequest(
            scope: ProcessingScopeSnapshot.capture(
                requestedTestArtists: artists,
                knownTrackCount: nil,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                reason: "observation fixture"
            ),
            refresh: refresh,
            previous: previous,
            inventory: inventory
        )
    }

    private func track(
        id: MusicDatabaseTrackID,
        artist: String,
        albumArtist: String? = nil,
        musicKitID: String? = nil
    ) -> Track {
        Track(
            id: musicKitID ?? id.rawValue,
            name: "Song \(id.rawValue)",
            artist: artist,
            album: "Album",
            genre: nil,
            year: 2001,
            dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
            lastModified: Date(timeIntervalSince1970: 1_650_000_000),
            trackStatus: nil,
            releaseYear: 2000,
            albumArtist: albumArtist,
            appleScriptID: id.rawValue
        )
    }

    private func identity(
        id: MusicDatabaseTrackID,
        artist: String?,
        albumArtist: String? = nil
    ) -> LibraryIdentityRow {
        LibraryIdentityRow(
            databaseID: id,
            artist: artist.map(Observed.value) ?? .absent,
            albumArtist: albumArtist.map(Observed.value) ?? .absent
        )
    }

    private func databaseID(_ rawValue: String) throws -> MusicDatabaseTrackID {
        try #require(MusicDatabaseTrackID(rawValue: rawValue))
    }

    private func libraryGeneration(_ rawValue: String) throws -> LibraryGeneration {
        try #require(LibraryGeneration(sourceValue: rawValue))
    }

    private func census(
        _ ids: [MusicDatabaseTrackID],
        generation: LibraryGeneration
    ) throws -> TrackIDCensus {
        try TrackIDCensus(ids: ids, totalCount: ids.count, generation: generation)
    }
}

private enum ObservationTestError: Error, Equatable {
    case censusFailed
}

private struct ScopedMetadataRequest: Equatable, Sendable {
    let databaseIDs: [MusicDatabaseTrackID]
    let scope: ProcessingScopeSnapshot
}

private actor ObservationSourceStub: ObservationSource {
    private var censuses: [TrackIDCensus]
    private var identities: [MusicDatabaseTrackID: LibraryIdentityRow]
    private var tracks: [MusicDatabaseTrackID: Track]
    private var latestCensus: TrackIDCensus?
    private let identityResponse: [LibraryIdentityRow]?
    private let censusError: ObservationTestError?
    private(set) var censusRequestCount = 0
    private(set) var identitySnapshotRequestCount = 0
    private(set) var scopedMetadataRequests: [ScopedMetadataRequest] = []

    init(
        censuses: [TrackIDCensus] = [],
        identities: [MusicDatabaseTrackID: LibraryIdentityRow]? = nil,
        identityResponse: [LibraryIdentityRow]? = nil,
        tracks: [MusicDatabaseTrackID: Track] = [:],
        censusError: ObservationTestError? = nil
    ) {
        self.censuses = censuses
        self.identities = identities ?? Dictionary(uniqueKeysWithValues: tracks.compactMap { databaseID, track in
            let row = LibraryIdentityRow(
                databaseID: databaseID,
                artist: .value(track.artist),
                albumArtist: track.albumArtist.map(Observed.value) ?? .absent
            )
            return (databaseID, row)
        })
        self.identityResponse = identityResponse
        self.tracks = tracks
        self.censusError = censusError
    }

    var scopedMetadataRequestIDs: [[MusicDatabaseTrackID]] {
        scopedMetadataRequests.map(\.databaseIDs)
    }

    func fetchIdentitySnapshot() throws -> LibraryIdentitySnapshot {
        identitySnapshotRequestCount += 1
        guard let latestCensus else {
            throw ObservationTestError.censusFailed
        }
        return LibraryIdentitySnapshot(
            census: latestCensus,
            rows: identityResponse ?? latestCensus.ids.compactMap { identities[$0] }
        )
    }

    func replaceLibrary(
        identities: [MusicDatabaseTrackID: LibraryIdentityRow],
        tracks: [MusicDatabaseTrackID: Track]
    ) {
        self.identities = identities
        self.tracks = tracks
    }

    func replaceCensus(_ census: TrackIDCensus) {
        censuses = [census]
    }

    func fetchCensus() throws -> TrackIDCensus {
        censusRequestCount += 1
        if let censusError {
            throw censusError
        }
        guard !censuses.isEmpty else {
            throw ObservationTestError.censusFailed
        }
        let census = censuses.count == 1 ? censuses[0] : censuses.removeFirst()
        latestCensus = census
        return census
    }

    func fetchProcessingMetadata(
        for databaseIDs: [MusicDatabaseTrackID],
        scope: ProcessingScopeSnapshot
    ) -> [Track] {
        scopedMetadataRequests.append(ScopedMetadataRequest(databaseIDs: databaseIDs, scope: scope))
        return databaseIDs.compactMap { tracks[$0] }
    }
}
