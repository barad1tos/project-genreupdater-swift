import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Python/Swift library convergence replay")
struct LibraryConvergenceReplayTests {
    @Test("reference covers every user-visible mirror convergence scenario")
    func coversRequiredScenarios() throws {
        let reference = try loadReference()

        #expect(reference.schemaVersion == 1)
        #expect(reference.pythonBaseline == "0f6dca1f36eab74a6899a0f770511927b68d3e15")
        #expect(Set(reference.cases.map(\.id)) == [
            "configured-force-refresh",
            "identity-change",
            "metadata-change",
            "new-track",
            "partial-response",
            "removed-track",
            "source-change-during-scan",
            "test-artists-change",
            "unchanged-library",
        ])
        #expect(reference.cases.allSatisfy { !$0.description.isEmpty })
    }

    @Test("Swift replays the pinned Python convergence scenarios")
    func swiftReplaysReferenceScenarios() async throws {
        for convergenceCase in try loadReference().cases {
            try await replay(convergenceCase)
        }
    }

    private func replay(_ convergenceCase: ConvergenceCase) async throws {
        let outcome = try await run(convergenceCase)
        assertPythonParity(convergenceCase, outcome: outcome)
        assertSwiftContract(convergenceCase, outcome: outcome)
    }

    private func assertPythonParity(_ convergenceCase: ConvergenceCase, outcome: ReplayOutcome) {
        let expected = convergenceCase.pythonExpected
        let context = convergenceCase.id

        #expect(outcome.membershipNewIDs == expected.membershipDelta.newIDs, "\(context): new membership")
        #expect(outcome.membershipRemovedIDs == expected.membershipDelta.removedIDs, "\(context): removed membership")
        #expect(
            outcome.finalMembershipIDs == convergenceCase.input.currentTracks.map(\.identifier).sorted(),
            "\(context): committed physical membership"
        )
        #expect(outcome.modifiedIDs == expected.managedMetadataChangedIDs, "\(context): managed metadata")
        #expect(outcome.identityChangedIDs == expected.identityChangedIDs, "\(context): identity changes")
        #expect(outcome.refreshedIDs.isEmpty, "\(context): no display-only fixture delta")
        #expect(outcome.admittedIDs == expected.admittedIDs, "\(context): processing admission")
        #expect(outcome.metadataRequestIDs == expected.metadataRequestIDs, "\(context): metadata request")
        #expect(outcome.metadataObservedIDs == expected.metadataObservedIDs, "\(context): metadata response")
        #expect(expected.readiness == nil, "\(context): Python has no persisted readiness certificate")
        #expect(expected.downstreamDecision == "continue-with-snapshot", "\(context): Python downstream decision")
    }

    private func assertSwiftContract(_ convergenceCase: ConvergenceCase, outcome: ReplayOutcome) {
        let expected = convergenceCase.pythonExpected
        let swiftExpected = convergenceCase.swiftExpected
        let context = convergenceCase.id
        #expect(
            outcome.identityRequestIDs == swiftExpected.identityRequestIDs,
            "\(context): identity classification request"
        )
        #expect(
            outcome.classificationUpsertedIDs == swiftExpected.persistedClassificationUpsertedIDs,
            "\(context): persisted classification upsert"
        )
        #expect(
            outcome.classificationRemovedIDs == swiftExpected.persistedClassificationRemovedIDs,
            "\(context): persisted classification removal"
        )
        #expect(outcome.isReady == swiftExpected.isReady, "\(context): Swift mirror readiness")
        let swiftDownstreamDecision = outcome.isReady
            ? "continue-with-committed-mirror"
            : "refuse-incomplete-observation"
        #expect(
            swiftDownstreamDecision == swiftExpected.downstreamDecision,
            "\(context): Swift downstream decision"
        )
        if convergenceCase.input.doesSourceChangeDuringScan {
            #expect(outcome.censusRequestCount == 4, "Swift must retry the whole fenced observation")
            #expect(
                swiftExpected.strongerContractReasons.contains { $0.contains("source-generation") },
                "\(context): stronger source fence must be explicit"
            )
        } else {
            #expect(outcome.censusRequestCount == 2, "\(context): one fenced observation")
        }
        let expectedProcessingNewIDs = Set(expected.admittedIDs)
            .subtracting(convergenceCase.input.previouslyAdmittedIDs)
            .sorted()
        #expect(outcome.processingNewIDs == expectedProcessingNewIDs, "\(context): processing-scope entry")
        #expect(outcome.processingRemovedIDs == expected.membershipDelta.removedIDs, "\(context): processing removal")
        assertInvalidations(
            outcome.invalidationTargets,
            pythonExpected: Set(expected.invalidationTargets),
            swiftExpected: swiftExpected,
            context: context
        )
        let hasStrongerReadiness = expected.readiness == nil && !swiftExpected.isReady
        #expect(
            hasStrongerReadiness
                == swiftExpected.strongerContractReasons.contains { $0.contains("incomplete metadata") },
            "\(context): stronger readiness refusal must be explicit"
        )
    }

    private func assertInvalidations(
        _ actual: Set<InvalidationTarget>,
        pythonExpected: Set<InvalidationTarget>,
        swiftExpected: SwiftExpectation,
        context: String
    ) {
        let expectedSwiftInvalidations = Set(swiftExpected.invalidationTargets)
        #expect(actual == expectedSwiftInvalidations, "\(context): closed invalidation set")
        #expect(
            actual.isSuperset(of: pythonExpected),
            "\(context): Python invalidations must be preserved"
        )
        let hasStrongerInvalidation = expectedSwiftInvalidations != pythonExpected
        #expect(
            hasStrongerInvalidation
                == swiftExpected.strongerContractReasons.contains { $0.contains("invalidates the closed") },
            "\(context): stronger invalidation must be explicit"
        )
    }

    private func run(_ convergenceCase: ConvergenceCase) async throws -> ReplayOutcome {
        let store = try TrackDataStore.createInMemory()
        let previousTracks = try convergenceCase.input.previousTracks.map(makeTrack)
        let currentTracks = try convergenceCase.input.currentTracks.map(makeTrack)
        let source = try ConvergenceObservationSource(
            censuses: repeatedCensus(
                tracks: previousTracks,
                generation: "\(convergenceCase.id)-baseline"
            ),
            tracks: previousTracks
        )
        let initialConfiguration = configuration(testArtists: convergenceCase.input.previousTestArtists)
        let service = LibrarySyncService(
            trackStore: store,
            runtimeConfiguration: initialConfiguration,
            observer: MusicAppObserver(source: source)
        )

        _ = try await service.synchronizeNow(forceMetadataRefresh: true)
        let baseline = try await store.loadMirrorSnapshot()
        try await completePendingEffects(in: store)

        try await source.configure(
            censuses: currentCensuses(
                for: convergenceCase,
                previousTracks: previousTracks,
                currentTracks: currentTracks
            ),
            tracks: currentTracks,
            metadataResponseIDs: Set(convergenceCase.input.metadataResponseIDs)
        )
        let currentConfiguration = configuration(testArtists: convergenceCase.input.testArtists)
        await service.updateRuntimeConfiguration(currentConfiguration)

        let result = try await service.synchronizeNow(
            forceMetadataRefresh: convergenceCase.input.forceMetadataRefresh
        )
        let snapshot = try await store.loadMirrorSnapshot()
        let observations = await source.observations()
        let effects = try await store.pendingMirrorEffects()
        let admittedIDs = try admittedIDs(
            snapshot: snapshot,
            testArtists: convergenceCase.input.testArtists
        )

        return makeOutcome(OutcomeInput(
            result: result,
            baseline: baseline,
            snapshot: snapshot,
            observations: observations,
            effects: effects,
            admittedIDs: admittedIDs,
            requirement: currentConfiguration.processingRequirement
        ))
    }

    private func currentCensuses(
        for convergenceCase: ConvergenceCase,
        previousTracks: [Track],
        currentTracks: [Track]
    ) throws -> [TrackIDCensus] {
        let currentGeneration = "\(convergenceCase.id)-current"
        guard convergenceCase.input.doesSourceChangeDuringScan else {
            return try repeatedCensus(tracks: currentTracks, generation: currentGeneration)
        }
        let stale = try census(tracks: previousTracks, generation: "\(convergenceCase.id)-stale")
        let current = try census(tracks: currentTracks, generation: currentGeneration)
        return [stale, current, current, current]
    }

    private func makeOutcome(_ input: OutcomeInput) -> ReplayOutcome {
        let result = input.result
        let snapshot = input.snapshot
        return ReplayOutcome(
            membershipNewIDs: snapshot.presentIDs.subtracting(input.baseline.presentIDs).rawValues,
            membershipRemovedIDs: input.baseline.presentIDs.subtracting(snapshot.presentIDs).rawValues,
            finalMembershipIDs: snapshot.presentIDs.rawValues,
            processingNewIDs: result.newTracks.map(\.id).sorted(),
            processingRemovedIDs: result.removedTrackIDs.sorted(),
            modifiedIDs: result.modifiedTracks.map(\.id).sorted(),
            identityChangedIDs: result.identityChangedTracks.map(\.id).sorted(),
            refreshedIDs: result.refreshedTracks.map(\.id).sorted(),
            admittedIDs: input.admittedIDs,
            identityRequestIDs: input.observations.identityRequests.flatMap(\.self).rawValues,
            metadataRequestIDs: input.observations.metadataRequests.flatMap(\.self).rawValues,
            metadataObservedIDs: input.observations.metadataResponses.flatMap(\.self).rawValues,
            classificationUpsertedIDs: input.snapshot.memberIdentities.compactMap { databaseID, identity in
                guard let baseline = input.baseline.memberIdentities[databaseID] else {
                    return databaseID.rawValue
                }
                return baseline.artist == identity.artist && baseline.albumArtist == identity.albumArtist
                    ? nil
                    : databaseID.rawValue
            }.sorted(),
            classificationRemovedIDs: input.baseline.memberIdentities.keys.filter {
                input.snapshot.memberIdentities[$0] == nil
            }.map(\.rawValue).sorted(),
            invalidationTargets: Set(input.effects.compactMap { pending in
                guard case let .invalidateAlbumYear(identity) = pending.effect else { return nil }
                return InvalidationTarget(artist: identity.artist, album: identity.album)
            }),
            isReady: snapshot.readiness(for: input.requirement, at: Date()).isReady,
            censusRequestCount: input.observations.censusRequestCount
        )
    }

    private func configuration(testArtists: [String]) -> LibrarySyncRuntimeConfiguration {
        LibrarySyncRuntimeConfiguration(
            forceMetadataScanIntervalDays: 0,
            testArtists: testArtists,
            mirrorRetryPolicy: MirrorRetryPolicy(retryLimit: 1, delay: .zero)
        )
    }

    private func makeTrack(_ fixture: FixtureTrack) throws -> Track {
        guard MusicDatabaseTrackID(rawValue: fixture.identifier) != nil else {
            throw ConvergenceReplayError.invalidTrackID(fixture.identifier)
        }
        return Track(
            id: fixture.identifier,
            name: "Track \(fixture.identifier)",
            artist: fixture.artist,
            album: fixture.album,
            genre: fixture.genre,
            year: fixture.year.flatMap(Int.init),
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            lastModified: Date(timeIntervalSince1970: 1_700_000_000),
            albumArtist: fixture.albumArtist,
            appleScriptID: fixture.identifier
        )
    }

    private func repeatedCensus(tracks: [Track], generation: String) throws -> [TrackIDCensus] {
        let value = try census(tracks: tracks, generation: generation)
        return [value, value]
    }

    private func census(tracks: [Track], generation: String) throws -> TrackIDCensus {
        let ids = try tracks.map { track in
            guard let databaseID = track.databaseID else {
                throw ConvergenceReplayError.invalidTrackID(track.id)
            }
            return databaseID
        }
        guard let libraryGeneration = LibraryGeneration(sourceValue: generation) else {
            throw ConvergenceReplayError.invalidGeneration(generation)
        }
        return try TrackIDCensus(ids: ids, totalCount: ids.count, generation: libraryGeneration)
    }

    private func completePendingEffects(in store: TrackDataStore) async throws {
        for effect in try await store.pendingMirrorEffects() {
            try await store.completeMirrorEffect(id: effect.id)
        }
    }

    private func admittedIDs(snapshot: TrackMirrorSnapshot, testArtists: [String]) throws -> [String] {
        guard !testArtists.isEmpty else { return snapshot.presentIDs.rawValues }
        guard let inventory = LibraryInventoryIndex(identitiesByID: snapshot.memberIdentities) else {
            throw ConvergenceReplayError.invalidInventory
        }
        let scope = ProcessingScopeSnapshot.capture(
            requestedTestArtists: testArtists,
            knownTrackCount: snapshot.presentTracks.count,
            createdAt: Date(),
            reason: "convergence replay"
        )
        return inventory.admittedIDs(
            censusIDs: snapshot.presentIDs,
            observed: [:],
            scope: scope
        ).rawValues
    }

    private func loadReference() throws -> ConvergenceReference {
        let url = try #require(
            Bundle.module.url(
                forResource: "library_convergence_reference",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ConvergenceReference.self, from: Data(contentsOf: url))
    }
}

private struct ReplayOutcome {
    let membershipNewIDs: [String]
    let membershipRemovedIDs: [String]
    let finalMembershipIDs: [String]
    let processingNewIDs: [String]
    let processingRemovedIDs: [String]
    let modifiedIDs: [String]
    let identityChangedIDs: [String]
    let refreshedIDs: [String]
    let admittedIDs: [String]
    let identityRequestIDs: [String]
    let metadataRequestIDs: [String]
    let metadataObservedIDs: [String]
    let classificationUpsertedIDs: [String]
    let classificationRemovedIDs: [String]
    let invalidationTargets: Set<InvalidationTarget>
    let isReady: Bool
    let censusRequestCount: Int
}

private struct OutcomeInput {
    let result: SyncResult
    let baseline: TrackMirrorSnapshot
    let snapshot: TrackMirrorSnapshot
    let observations: SourceObservations
    let effects: [PendingMirrorEffect]
    let admittedIDs: [String]
    let requirement: MirrorRequirement
}

private enum ConvergenceReplayError: Error {
    case invalidTrackID(String)
    case invalidGeneration(String)
    case invalidInventory
    case missingCensus
}

private actor ConvergenceObservationSource: ObservationSource {
    private var censuses: [TrackIDCensus]
    private var identities: [MusicDatabaseTrackID: LibraryIdentityRow]
    private var tracks: [MusicDatabaseTrackID: Track]
    private var metadataResponseIDs: Set<MusicDatabaseTrackID>
    private var latestCensus: TrackIDCensus?
    private var censusRequestCount = 0
    private var identityRequests: [[MusicDatabaseTrackID]] = []
    private var metadataRequests: [[MusicDatabaseTrackID]] = []
    private var metadataResponses: [[MusicDatabaseTrackID]] = []

    init(censuses: [TrackIDCensus], tracks: [Track]) throws {
        self.censuses = censuses
        let indexed = try Self.index(tracks)
        identities = Self.identities(from: indexed)
        self.tracks = indexed
        metadataResponseIDs = Set(indexed.keys)
    }

    func configure(
        censuses: [TrackIDCensus],
        tracks: [Track],
        metadataResponseIDs: Set<String>
    ) throws {
        self.censuses = censuses
        let indexed = try Self.index(tracks)
        identities = Self.identities(from: indexed)
        self.tracks = indexed
        self.metadataResponseIDs = try Set(metadataResponseIDs.map { rawValue in
            guard let databaseID = MusicDatabaseTrackID(rawValue: rawValue) else {
                throw ConvergenceReplayError.invalidTrackID(rawValue)
            }
            return databaseID
        })
        latestCensus = nil
        censusRequestCount = 0
        identityRequests = []
        metadataRequests = []
        metadataResponses = []
    }

    func fetchCensus() throws -> TrackIDCensus {
        censusRequestCount += 1
        guard !censuses.isEmpty else { throw ConvergenceReplayError.missingCensus }
        let census = censuses.count == 1 ? censuses[0] : censuses.removeFirst()
        latestCensus = census
        return census
    }

    func fetchIdentitySnapshot() throws -> LibraryIdentitySnapshot {
        guard let latestCensus else { throw ConvergenceReplayError.missingCensus }
        identityRequests.append(latestCensus.ids)
        return LibraryIdentitySnapshot(
            census: latestCensus,
            rows: latestCensus.ids.compactMap { identities[$0] }
        )
    }

    func fetchProcessingMetadata(
        for databaseIDs: [MusicDatabaseTrackID],
        scope _: ProcessingScopeSnapshot
    ) -> [Track] {
        metadataRequests.append(databaseIDs)
        let response = databaseIDs.filter(metadataResponseIDs.contains)
        metadataResponses.append(response)
        return response.compactMap { tracks[$0] }
    }

    func observations() -> SourceObservations {
        SourceObservations(
            censusRequestCount: censusRequestCount,
            identityRequests: identityRequests,
            metadataRequests: metadataRequests,
            metadataResponses: metadataResponses
        )
    }

    private static func index(_ tracks: [Track]) throws -> [MusicDatabaseTrackID: Track] {
        try Dictionary(uniqueKeysWithValues: tracks.map { track in
            guard let databaseID = track.databaseID else {
                throw ConvergenceReplayError.invalidTrackID(track.id)
            }
            return (databaseID, track)
        })
    }

    private static func identities(
        from tracks: [MusicDatabaseTrackID: Track]
    ) -> [MusicDatabaseTrackID: LibraryIdentityRow] {
        Dictionary(uniqueKeysWithValues: tracks.map { databaseID, track in
            (databaseID, LibraryIdentityRow(
                databaseID: databaseID,
                artist: .value(track.artist),
                albumArtist: track.albumArtist.map(Observed.value) ?? .absent
            ))
        })
    }
}

private struct SourceObservations: Sendable {
    let censusRequestCount: Int
    let identityRequests: [[MusicDatabaseTrackID]]
    let metadataRequests: [[MusicDatabaseTrackID]]
    let metadataResponses: [[MusicDatabaseTrackID]]
}

extension Set<MusicDatabaseTrackID> {
    fileprivate var rawValues: [String] {
        map(\.rawValue).sorted()
    }
}

extension [MusicDatabaseTrackID] {
    fileprivate var rawValues: [String] {
        map(\.rawValue).sorted()
    }
}

private struct ConvergenceReference: Decodable {
    let schemaVersion: Int
    let pythonBaseline: String
    let cases: [ConvergenceCase]
}

private struct ConvergenceCase: Decodable {
    let id: String
    let description: String
    let input: ConvergenceInput
    let pythonExpected: PythonExpectation
    let swiftExpected: SwiftExpectation
}

private struct ConvergenceInput: Decodable {
    let previousTracks: [FixtureTrack]
    let currentTracks: [FixtureTrack]
    let previousTestArtists: [String]
    let testArtists: [String]
    let forceMetadataRefresh: Bool
    let metadataResponseIDs: [String]
    let doesSourceChangeDuringScan: Bool

    private enum CodingKeys: String, CodingKey {
        case previousTracks
        case currentTracks
        case previousTestArtists
        case testArtists
        case forceMetadataRefresh
        case metadataResponseIDs
        case doesSourceChangeDuringScan = "sourceChangesDuringScan"
    }

    var previouslyAdmittedIDs: Set<String> {
        guard !previousTestArtists.isEmpty else {
            return Set(previousTracks.map(\.identifier))
        }
        let selectedArtists = Set(previousTestArtists)
        return Set(previousTracks.compactMap { track in
            selectedArtists.contains(track.artist) || track.albumArtist.map(selectedArtists.contains) == true
                ? track.identifier
                : nil
        })
    }
}

private struct FixtureTrack: Decodable {
    let identifier: String
    let artist: String
    let album: String
    let albumArtist: String?
    let genre: String?
    let year: String?
}

private struct PythonExpectation: Decodable {
    let membershipDelta: MembershipDelta
    let managedMetadataChangedIDs: [String]
    let identityChangedIDs: [String]
    let admittedIDs: [String]
    let metadataRequestIDs: [String]
    let metadataObservedIDs: [String]
    let invalidationTargets: [InvalidationTarget]
    let readiness: String?
    let downstreamDecision: String
}

private struct SwiftExpectation: Decodable {
    let identityRequestIDs: [String]
    let persistedClassificationUpsertedIDs: [String]
    let persistedClassificationRemovedIDs: [String]
    let invalidationTargets: [InvalidationTarget]
    let isReady: Bool
    let downstreamDecision: String
    let strongerContractReasons: [String]
}

private struct MembershipDelta: Decodable {
    let newIDs: [String]
    let removedIDs: [String]
}

private struct InvalidationTarget: Decodable, Equatable, Hashable {
    let artist: String
    let album: String
}
