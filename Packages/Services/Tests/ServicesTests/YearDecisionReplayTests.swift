import Core
import Foundation
import Testing
@testable import Services

@Suite("Python year-decision replay", .serialized)
struct YearDecisionReplayTests {
    @Test("Core reproduces every generated decision tuple")
    func coreDecisionParity() throws {
        let fixture = try loadFixture()
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.contract == "post_acquisition_scored_release_decision")

        for replayCase in fixture.cases {
            try assertCoreParity(replayCase, fixture: fixture)
        }
    }

    @Test("Services reproduces Python effects behind Swift write safety")
    func serviceEffectParity() async throws {
        let fixture = try loadFixture()

        for replayCase in fixture.cases {
            try await assertServiceParity(replayCase, fixture: fixture)
        }
    }

    private func assertCoreParity(_ replayCase: ReplayCase, fixture: Fixture) throws {
        let input = replayCase.input
        let decisionDate = try fixture.decisionDate()
        let scorer = makeScorer(input.scoring)
        let determinator = YearDeterminator(scorer: scorer, fallback: YearFallbackStrategy())
        let tracks = makeTracks(input)
        let candidates = input.candidates.compactMap(makeCandidate)
        let scored = candidates
            .filter { determinator.validator.acceptsCandidateYear($0.year, at: decisionDate) }
            .map {
                scorer.scoreRelease(
                    $0,
                    queryArtist: "Artist",
                    queryAlbum: input.album,
                    currentYear: input.existingYear,
                    decisionDate: decisionDate
                )
            }
        let result = determinator.determineYear(
            candidates: candidates,
            track: tracks[0],
            albumTracks: tracks,
            currentYear: input.existingYear,
            artistStartYear: input.artistStartYear,
            albumTypeInfo: AlbumTypeDetectionConfig().classifyAlbum(input.album),
            verificationAttempts: input.startingAttempts,
            usesLocalEvidence: false,
            decisionDate: decisionDate
        )

        assertScoring(scored, for: replayCase)
        assertDecision(result, for: replayCase)
    }

    private func assertScoring(_ scored: [ScoredRelease], for replayCase: ReplayCase) {
        let expected = replayCase.expected
        let inputScores = replayCase.input.candidates.compactMap { candidate in
            candidate.year.map { _ in candidate.score }
        }.filter { score in
            expected.acceptedScoreLists.values.joined().contains(score)
        }
        #expect(
            scored.map(\.totalScore) == inputScores,
            "\(replayCase.id): Swift scoring must reproduce the Python scored-release inputs"
        )
        #expect(scoreLists(scored) == expected.acceptedScoreLists, "\(replayCase.id): accepted score lists")
    }

    private func assertDecision(_ result: YearDeterminationResult, for replayCase: ReplayCase) {
        let expected = replayCase.expected
        #expect(result.rejectedCandidateYears == expected.rejectedYears, "\(replayCase.id): rejected years")
        #expect(
            result.candidateCount + expected.rejectedMissingYearCount == replayCase.input.candidates.count,
            "\(replayCase.id): Swift has no missing-year ReleaseCandidate state"
        )
        #expect(result.scoredYearResult?.year == expected.selectedYear, "\(replayCase.id): selected year")
        #expect(result.scoredYearResult?.isDefinitive == expected.isDefinitive, "\(replayCase.id): definitiveness")
        #expect(result.scoredYearResult?.confidence == expected.confidence, "\(replayCase.id): confidence")
        #expect(result.scoredYearResult?.yearScores == expected.yearScores, "\(replayCase.id): MAX score per year")
        #expect(result.yearResult.year == expected.finalYear, "\(replayCase.id): final year")
        #expect(
            operations(from: result.verificationMutations) == expected.pendingOperations,
            "\(replayCase.id): pending operation sequence"
        )
    }

    private func assertServiceParity(_ replayCase: ReplayCase, fixture: Fixture) async throws {
        let context = try makeServiceContext(replayCase, fixture: fixture)
        let actualProposals = try await collectProposals(context)
        let cached = await context.cache.getAlbumYear(artist: "Artist", album: replayCase.input.album)
        let actualCache = cached.map { CacheStore(year: $0.year, confidence: $0.confidence) }
        let expected = serviceEffects(for: replayCase)

        #expect(actualProposals == expected.proposals, "\(replayCase.id): proposals")
        #expect(
            await context.pending.operations == expected.pendingOperations,
            "\(replayCase.id): persisted pending operations"
        )
        #expect(await context.pending.current == expected.pendingFinal, "\(replayCase.id): final pending row")
        #expect(actualCache == expected.cacheStore, "\(replayCase.id): album decision cache")
    }

    private func makeServiceContext(_ replayCase: ReplayCase, fixture: Fixture) throws -> ServiceReplayContext {
        let input = replayCase.input
        let decisionDate = try fixture.decisionDate()
        let tracks = makeTracks(input)
        let pending = ReplayPendingStore(
            artist: "Artist",
            album: input.album,
            startingAttempts: input.startingAttempts,
            now: decisionDate
        )
        let cache = MockCacheService()
        let service = MockAPIService(
            releaseCandidates: input.candidates.compactMap(makeCandidate),
            artistActivityPeriod: (input.artistStartYear, nil),
            artistStartYear: input.artistStartYear
        )
        let bridge = MockAppleScriptClient()
        let coordinator = UpdateCoordinator(
            dependencies: UpdateDependencies(
                apiOrchestrator: makeAPIOrchestrator(
                    musicBrainz: service,
                    discogs: MockAPIService(),
                    appleMusic: MockAPIService()
                ),
                scriptBridge: bridge,
                stores: .init(trackStore: MockTrackStore(), cache: cache),
                undoCoordinator: UndoCoordinator(
                    scriptBridge: bridge,
                    directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("YearDecisionReplay-\(UUID().uuidString)")
                ),
                pendingVerificationService: pending
            ),
            genreDeterminator: GenreDeterminator(),
            yearDeterminator: YearDeterminator(
                scorer: makeScorer(input.scoring),
                fallback: YearFallbackStrategy()
            ),
            decisionDate: { decisionDate }
        )
        return ServiceReplayContext(
            coordinator: coordinator,
            tracks: tracks,
            pending: pending,
            cache: cache,
            runScope: YearRunScope()
        )
    }

    private func collectProposals(_ context: ServiceReplayContext) async throws -> [Proposal] {
        var proposals: [ProposedChange] = []
        for track in context.tracks {
            try await proposals.append(contentsOf: context.coordinator.updateTrack(
                track,
                albumTracks: context.tracks,
                options: UpdateOptions(
                    updateGenre: false,
                    updateYear: true,
                    forceYearLookup: true,
                    minConfidence: 0
                ),
                dryRun: true,
                yearRunScope: context.runScope
            ))
        }
        return proposals
            .filter { $0.changeType == .yearUpdate }
            .map {
                Proposal(
                    trackID: $0.track.id,
                    oldYear: $0.oldValue.flatMap(Int.init),
                    newYear: $0.newValue.flatMap(Int.init)
                )
            }
    }

    private func serviceEffects(for replayCase: ReplayCase) -> ServiceEffects {
        let input = replayCase.input
        let python = replayCase.expected
        let rejectsReleaseConflict = input.existingYear != nil
            && input.releaseYear != nil
            && input.existingYear != input.releaseYear
            && python.finalYear != input.releaseYear
        return ServiceEffects(
            proposals: rejectsReleaseConflict ? [] : python.proposals,
            pendingOperations: python.pendingOperations,
            pendingFinal: python.pendingFinal,
            cacheStore: rejectsReleaseConflict ? nil : python.cacheStore
        )
    }

    private func loadFixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(
                forResource: "year_decision_reference",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func makeTracks(_ input: Input) -> [Track] {
        (1 ... 2).map { index in
            Track(
                id: "track-\(index)",
                name: "Track \(index)",
                artist: "Artist",
                album: input.album,
                year: input.existingYear,
                trackStatus: "purchased",
                releaseYear: input.releaseYear
            )
        }
    }

    private func makeCandidate(_ input: Candidate) -> ReleaseCandidate? {
        guard let year = input.year, let source = APISource(rawValue: input.source) else {
            return nil
        }
        return ReleaseCandidate(
            artist: "Artist",
            album: "Album",
            year: year,
            source: source,
            releaseType: .other,
            status: .other
        )
    }

    private func makeScorer(_ profile: ScoringProfile) -> YearScorer {
        var scoring = ScoringConfig()
        scoring.baseScore = profile.baseScore
        scoring.artistExactMatchBonus = 0
        scoring.artistSubstringPenalty = 0
        scoring.artistCrossScriptPenalty = 0
        scoring.artistMismatchPenalty = 0
        scoring.albumExactMatchBonus = 0
        scoring.perfectMatchBonus = 0
        scoring.albumSubstringPenalty = 0
        scoring.albumUnrelatedPenalty = 0
        scoring.soundtrackCompensationBonus = 0
        scoring.mbReleaseGroupMatchBonus = 0
        scoring.typeAlbumBonus = 0
        scoring.typeEPSinglePenalty = 0
        scoring.typeCompilationLivePenalty = 0
        scoring.statusOfficialBonus = 0
        scoring.statusBootlegPenalty = 0
        scoring.statusPromoPenalty = 0
        scoring.reissuePenalty = 0
        scoring.yearDiffPenaltyScale = 0
        scoring.yearDiffMaxPenalty = 0
        scoring.yearBeforeStartPenalty = 0
        scoring.yearAfterEndPenalty = 0
        scoring.yearNearStartBonus = 0
        scoring.countryArtistMatchBonus = 0
        scoring.countryMajorMarketBonus = 0
        scoring.sourceMBBonus = profile.musicBrainzBonus
        scoring.sourceDiscogsBonus = 0
        scoring.sourceITunesBonus = profile.itunesBonus
        scoring.futureYearPenalty = 0
        scoring.currentYearPenalty = 0
        return YearScorer(
            config: scoring,
            editionKeywords: MetadataRuleDefaults.releaseReissues
        )
    }

    private func scoreLists(_ releases: [ScoredRelease]) -> [String: [Int]] {
        Dictionary(grouping: releases, by: { String($0.candidate.year) })
            .mapValues { $0.map(\.totalScore) }
    }

    private func operations(from mutations: [YearVerificationMutation]) -> [PendingOperation] {
        mutations.map { mutation in
            switch mutation {
            case let .mark(reason, metadata):
                PendingOperation(kind: "mark", reason: reason.rawValue, metadata: metadata)
            case .remove:
                PendingOperation(kind: "remove", reason: nil, metadata: nil)
            }
        }
    }
}

private struct Fixture: Decodable {
    let schemaVersion: Int
    let pythonBaseline: String
    let contract: String
    let decisionYear: Int
    let cases: [ReplayCase]

    func decisionDate() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return try #require(calendar.date(from: DateComponents(year: decisionYear, month: 1, day: 15)))
    }
}

private struct ReplayCase: Decodable {
    let id: String
    let input: Input
    let expected: Expected
}

private struct Input: Decodable {
    let album: String
    let existingYear: Int?
    let releaseYear: Int?
    let artistStartYear: Int?
    let startingAttempts: Int
    let candidates: [Candidate]
    let scoring: ScoringProfile

    private enum CodingKeys: String, CodingKey {
        case album, existingYear, releaseYear, artistStartYear, startingAttempts, candidates, scoring
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        album = try container.decode(String.self, forKey: .album)
        existingYear = try container.decodeIfPresent(Int.self, forKey: .existingYear)
        releaseYear = try container.decodeIfPresent(Int.self, forKey: .releaseYear)
        artistStartYear = try container.decodeIfPresent(Int.self, forKey: .artistStartYear)
        startingAttempts = try container.decodeIfPresent(Int.self, forKey: .startingAttempts) ?? 0
        candidates = try container.decode([Candidate].self, forKey: .candidates)
        scoring = try container.decode(ScoringProfile.self, forKey: .scoring)
    }
}

private struct Candidate: Decodable {
    let year: Int?
    let score: Int
    let source: String
}

private struct ScoringProfile: Decodable {
    let baseScore: Int
    let musicBrainzBonus: Int
    let itunesBonus: Int
}

private struct Expected: Decodable {
    let acceptedScoreLists: [String: [Int]]
    let rejectedYears: [Int]
    let rejectedMissingYearCount: Int
    let selectedYear: Int?
    let isDefinitive: Bool
    let confidence: Int
    let yearScores: [Int: Int]
    let finalYear: Int?
    let pendingOperations: [PendingOperation]
    let pendingFinal: PendingFinal?
    let cacheStore: CacheStore?
    let proposals: [Proposal]
}

private struct PendingOperation: Codable, Equatable, Sendable {
    let kind: String
    let reason: String?
    let metadata: [String: String]?
}

private struct PendingFinal: Decodable, Equatable, Sendable {
    let reason: String
    let metadata: [String: String]
    let attemptCount: Int
}

private struct CacheStore: Decodable, Equatable {
    let year: Int?
    let confidence: Int
}

private struct Proposal: Decodable, Equatable {
    let trackID: String
    let oldYear: Int?
    let newYear: Int?
}

private struct ServiceEffects {
    let proposals: [Proposal]
    let pendingOperations: [PendingOperation]
    let pendingFinal: PendingFinal?
    let cacheStore: CacheStore?
}

private struct ServiceReplayContext {
    let coordinator: UpdateCoordinator
    let tracks: [Track]
    let pending: ReplayPendingStore
    let cache: MockCacheService
    let runScope: YearRunScope
}

private actor ReplayPendingStore: PendingVerificationService {
    private let artist: String
    private let album: String
    private let now: Date
    private var entry: PendingAlbumEntry?
    private(set) var operations: [PendingOperation] = []

    init(artist: String, album: String, startingAttempts: Int, now: Date) {
        self.artist = artist
        self.album = album
        self.now = now
        entry = startingAttempts > 0
            ? PendingAlbumEntry(
                id: AlbumIdentity.key(artist: artist, album: album),
                artist: artist,
                album: album,
                reason: "no_year_found",
                retry: .init(attemptCount: startingAttempts, lastAttempt: now)
            )
            : nil
    }

    var current: PendingFinal? {
        entry.map {
            PendingFinal(reason: $0.reason, metadata: $0.metadata, attemptCount: $0.attemptCount)
        }
    }

    func initialize() async throws {
        try Task.checkCancellation()
    }

    func markForVerification(
        artist: String,
        album: String,
        reason: String,
        metadata: [String: String]?,
        recheckDays _: Int?
    ) async {
        let attemptCount = (entry?.attemptCount ?? 0) + 1
        let storedMetadata = metadata ?? [:]
        entry = PendingAlbumEntry(
            id: AlbumIdentity.key(artist: artist, album: album),
            artist: artist,
            album: album,
            reason: reason,
            retry: .init(attemptCount: attemptCount, lastAttempt: now),
            metadata: storedMetadata
        )
        operations.append(PendingOperation(kind: "mark", reason: reason, metadata: storedMetadata))
    }

    func removeFromPending(artist _: String, album _: String) async {
        entry = nil
        operations.append(PendingOperation(kind: "remove", reason: nil, metadata: nil))
    }

    func getEntry(artist: String, album: String) async -> PendingAlbumEntry? {
        artist == self.artist && album == self.album ? entry : nil
    }

    func getAttemptCount(artist: String, album: String) async -> Int {
        guard artist == self.artist, album == self.album else { return 0 }
        return entry?.attemptCount ?? 0
    }

    func isVerificationNeeded(artist _: String, album _: String) async -> Bool {
        true
    }

    func getAllPendingAlbums() async -> [PendingAlbumEntry] {
        entry.map { [$0] } ?? []
    }

    func shouldAutoVerify() async -> Bool {
        false
    }

    func updateVerificationTimestamp() async throws {
        try Task.checkCancellation()
    }
}
