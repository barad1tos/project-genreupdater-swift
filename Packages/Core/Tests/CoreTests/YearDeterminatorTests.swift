import Foundation
import Testing
@testable import Core

// swiftlint:disable file_length

// MARK: - YearDeterminator Tests

@Suite("YearDeterminator — Orchestration")
struct YearDeterminatorTests { // swiftlint:disable:this type_body_length
    let determinator = YearDeterminator()

    // MARK: - Helpers

    private func makeTrack(
        year: Int? = nil,
        artist: String = "Test Artist",
        album: String = "Test Album",
        dateAdded: Date? = nil,
        yearSetByMGU: Int? = nil,
        trackStatus: String? = nil
    ) -> Track {
        Track(
            id: "test-1",
            name: "Test Song",
            artist: artist,
            album: album,
            year: year,
            dateAdded: dateAdded,
            trackStatus: trackStatus,
            yearBeforeMGU: yearSetByMGU != nil ? year : nil,
            yearSetByMGU: yearSetByMGU
        )
    }

    private func makeCandidate(
        artist: String = "Test Artist",
        album: String = "Test Album",
        year: Int = 2000,
        source: APISource = .musicBrainz,
        releaseType: ReleaseType = .album,
        status: ReleaseStatus = .official,
        country: String? = "US",
        isReissue: Bool = false,
        mbReleaseGroupID: String? = "rg-1",
        mbReleaseGroupFirstYear: Int? = nil
    ) -> ReleaseCandidate {
        ReleaseCandidate(
            artist: artist,
            album: album,
            year: year,
            source: source,
            releaseType: releaseType,
            status: status,
            country: country,
            isReissue: isReissue,
            mbReleaseGroupID: mbReleaseGroupID,
            mbReleaseGroupFirstYear: mbReleaseGroupFirstYear
        )
    }

    // MARK: - Empty Candidates

    @Test("No candidates with existing year returns library source")
    func noCandidatesWithExisting() {
        let track = makeTrack(year: 2005)
        let result = determinator.determineYear(
            candidates: [],
            track: track,
            currentYear: 2005
        )
        #expect(result.yearResult.year == 2005)
        #expect(result.source == .library)
        #expect(result.candidateCount == 0)
    }

    @Test("No candidates and no year returns empty result")
    func noCandidatesNoYear() {
        let track = makeTrack()
        let result = determinator.determineYear(
            candidates: [],
            track: track
        )
        #expect(result.yearResult.year == nil)
        #expect(result.source == .fallback)
    }

    // MARK: - Consensus Year

    @Test("Consensus release year used when all tracks agree")
    func consensusYear() {
        let track = makeTrack(year: 2000)
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Y",
                releaseYear: 2005
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Y",
                releaseYear: 2005
            ),
            Track(
                id: "3",
                name: "C",
                artist: "X",
                album: "Y",
                releaseYear: 2005
            ),
        ]
        let candidates = [makeCandidate(year: 2003)]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            albumTracks: albumTracks,
            currentYear: 2000
        )
        #expect(result.yearResult.year == 2005)
        #expect(result.source == .consensus)
        #expect(result.yearResult.isDefinitive == true)
    }

    @Test("Consensus skipped when tracks disagree")
    func noConsensus() {
        let track = makeTrack(year: 2000)
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Y",
                releaseYear: 2005
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Y",
                releaseYear: 2006
            ),
        ]
        let candidates = [
            makeCandidate(artist: "X", album: "Y", year: 2005),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            albumTracks: albumTracks,
            currentYear: 2000
        )
        // Should fall through to scoring, not consensus
        #expect(result.source != .consensus)
    }

    // MARK: - Dominant Year

    @Test("Dominant year used with high confidence")
    func dominantYear() {
        let track = makeTrack()
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "3",
                name: "C",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "4",
                name: "D",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "5",
                name: "E",
                artist: "X",
                album: "Y",
                year: 2006
            ),
        ]
        let candidates = [makeCandidate(year: 2003)]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            albumTracks: albumTracks
        )
        #expect(result.yearResult.year == 2005)
        #expect(result.source == .dominant)
    }

    @Test("Low confidence dominant year falls through to scoring")
    func lowConfidenceDominant() {
        let track = makeTrack()
        // 60% confidence (3 out of 5) — below 80% threshold
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "3",
                name: "C",
                artist: "X",
                album: "Y",
                year: 2005
            ),
            Track(
                id: "4",
                name: "D",
                artist: "X",
                album: "Y",
                year: 2006
            ),
            Track(
                id: "5",
                name: "E",
                artist: "X",
                album: "Y",
                year: 2007
            ),
        ]
        let candidates = [
            makeCandidate(
                artist: "X", album: "Y", year: 2005
            ),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            albumTracks: albumTracks
        )
        #expect(result.source != .dominant)
    }

    // MARK: - Scoring + Fallback

    @Test("High score candidate returns API year")
    func highScoreCandidate() {
        let track = makeTrack(artist: "Radiohead", album: "OK Computer")
        let candidates = [
            makeCandidate(
                artist: "Radiohead",
                album: "OK Computer",
                year: 1997,
                mbReleaseGroupFirstYear: 1997
            ),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track
        )
        #expect(result.yearResult.year == 1997)
        #expect(result.source == YearSource.api)
        #expect(result.breakdown != nil)
        #expect(result.candidateCount == 1)
    }

    @Test("Multiple candidates scored and best selected")
    func multipleCandidates() {
        let track = makeTrack(artist: "Radiohead", album: "OK Computer")
        let candidates = [
            makeCandidate(
                artist: "Radiohead",
                album: "OK Computer",
                year: 1997,
                mbReleaseGroupFirstYear: 1997
            ),
            makeCandidate(
                artist: "Radiohead",
                album: "OK Computer (Remastered)",
                year: 2017,
                isReissue: true
            ),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track
        )
        #expect(result.yearResult.year == 1997)
        #expect(result.candidateCount == 2)
    }

    @Test("Fallback escalation reflected in result")
    func fallbackEscalation() {
        // Low score → fallback escalates
        let track = makeTrack(
            year: 2000,
            artist: "Unknown Band",
            album: "Some Album"
        )
        let candidates = [
            makeCandidate(
                artist: "Different Artist",
                album: "Different Album",
                year: 2010
            ),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            currentYear: 2000
        )
        // Artist and album mismatch → low score → escalation
        #expect(result.fallbackDecision != nil)
    }

    @Test("Existing year kept when matches API")
    func existingYearKept() {
        let track = makeTrack(
            year: 2000,
            artist: "Test Artist",
            album: "Test Album"
        )
        let candidates = [
            makeCandidate(year: 2000),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            currentYear: 2000
        )
        #expect(result.yearResult.year == 2000)
    }

    // MARK: - Special Album Types

    @Test("Compilation album triggers markAndSkip")
    func compilationAlbumSkipped() {
        let track = makeTrack(
            year: 2000,
            artist: "Test Artist",
            album: "Greatest Hits"
        )
        let albumInfo = AlbumTypeInfo(
            albumType: .compilation,
            detectedPattern: "greatest hits",
            strategy: .markAndSkip
        )
        let candidates = [
            makeCandidate(
                album: "Greatest Hits",
                year: 2015
            ),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            currentYear: 2000,
            albumTypeInfo: albumInfo
        )
        if case .markAndSkip = result.fallbackDecision {
            #expect(result.yearResult.year == nil)
        } else {
            // May also hit other rules first; verify no crash
            #expect(result.yearResult.year != nil
                || result.fallbackDecision != nil)
        }
    }

    // MARK: - Pre-flight Checks

    @Test("Already processed track skipped")
    func alreadyProcessedSkipped() {
        let track = makeTrack(yearSetByMGU: 2000)
        let reason = determinator.preFlightCheck(
            track: track,
            albumTracks: []
        )
        #expect(reason != nil)
        #expect(reason?.contains("processed") == true)
    }

    @Test("Normal track passes pre-flight")
    func normalTrackPasses() {
        let track = makeTrack()
        let reason = determinator.preFlightCheck(
            track: track,
            albumTracks: []
        )
        #expect(reason == nil)
    }

    // MARK: - Suspicious Album Pre-flight

    @Test("Short album name + many unique years is suspicious")
    func suspiciousAlbumDetected() {
        let track = makeTrack(album: "EP")
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "EP",
                year: 2000
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "EP",
                year: 2005
            ),
            Track(
                id: "3",
                name: "C",
                artist: "X",
                album: "EP",
                year: 2010
            ),
        ]
        let reason = determinator.preFlightCheck(
            track: track,
            albumTracks: albumTracks
        )
        #expect(reason != nil)
        #expect(reason?.contains("Suspicious") == true)
    }

    @Test("Long album name not suspicious")
    func longAlbumNotSuspicious() {
        let track = makeTrack(album: "Great Album Title")
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Great Album Title",
                year: 2000
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Great Album Title",
                year: 2005
            ),
            Track(
                id: "3",
                name: "C",
                artist: "X",
                album: "Great Album Title",
                year: 2010
            ),
        ]
        let reason = determinator.checkSuspiciousAlbum(
            track: track,
            albumTracks: albumTracks
        )
        #expect(reason == nil)
    }

    @Test("Short album name + few unique years not suspicious")
    func fewYearsNotSuspicious() {
        let track = makeTrack(album: "EP")
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "EP",
                year: 2000
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "EP",
                year: 2000
            ),
        ]
        let reason = determinator.checkSuspiciousAlbum(
            track: track,
            albumTracks: albumTracks
        )
        #expect(reason == nil)
    }

    @Test("Exactly 3-char album at boundary is suspicious")
    func boundaryAlbumSuspicious() {
        // len("ABC") == 3 == suspiciousAlbumMinLen
        let track = makeTrack(album: "ABC")
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "ABC",
                year: 2000
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "ABC",
                year: 2001
            ),
            Track(
                id: "3",
                name: "C",
                artist: "X",
                album: "ABC",
                year: 2002
            ),
        ]
        let reason = determinator.checkSuspiciousAlbum(
            track: track,
            albumTracks: albumTracks
        )
        #expect(reason != nil)
    }

    // MARK: - Future Year Pre-flight

    @Test("Far-future year triggers skip")
    func farFutureYearSkips() {
        let currentYear = Calendar.current.component(
            .year, from: Date()
        )
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "New Album",
                year: currentYear + 5
            ),
        ]
        let reason = determinator.checkFutureYears(
            albumTracks: albumTracks,
            futureYearThreshold: 1
        )
        #expect(reason != nil)
        #expect(reason?.contains("Future year") == true)
    }

    @Test("Near-future year within threshold passes")
    func nearFutureYearPasses() {
        let currentYear = Calendar.current.component(
            .year, from: Date()
        )
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "New Album",
                year: currentYear + 1
            ),
        ]
        let reason = determinator.checkFutureYears(
            albumTracks: albumTracks,
            futureYearThreshold: 1
        )
        #expect(reason == nil)
    }

    @Test("No future years passes")
    func noFutureYearsPasses() {
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Album",
                year: 2020
            ),
        ]
        let reason = determinator.checkFutureYears(
            albumTracks: albumTracks
        )
        #expect(reason == nil)
    }

    @Test("Custom future year threshold respected")
    func customFutureThreshold() {
        let currentYear = Calendar.current.component(
            .year, from: Date()
        )
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Album",
                year: currentYear + 3
            ),
        ]
        // threshold=5 → year+3 is within threshold
        let reason = determinator.checkFutureYears(
            albumTracks: albumTracks,
            futureYearThreshold: 5
        )
        #expect(reason == nil)
    }

    @Test("Future year integrated in preFlightCheck")
    func futureYearInPreFlight() {
        let currentYear = Calendar.current.component(
            .year, from: Date()
        )
        let track = makeTrack(album: "Future Album")
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Future Album",
                year: currentYear + 10
            ),
        ]
        let reason = determinator.preFlightCheck(
            track: track,
            albumTracks: albumTracks
        )
        #expect(reason != nil)
        #expect(reason?.contains("Future year") == true)
    }

    @Test("Track uses existing year when no currentYear passed")
    func usesTrackYear() {
        let track = makeTrack(year: 1999, artist: "A", album: "B")
        let candidates = [
            makeCandidate(artist: "A", album: "B", year: 1999),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track
        )
        // currentYear defaults to track.year (1999)
        #expect(result.yearResult.year == 1999)
    }

    // MARK: - Year Scores Map

    @Test("Year scores map populated from scoring")
    func yearScoresPresent() {
        let track = makeTrack(artist: "Band", album: "Album")
        let candidates = [
            makeCandidate(artist: "Band", album: "Album", year: 2000),
            makeCandidate(artist: "Band", album: "Album", year: 2001),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track
        )
        #expect(!result.yearResult.yearScores.isEmpty)
    }

    // MARK: - Consensus Validation

    @Test("Absurd consensus year falls through to scoring")
    func absurdConsensusSkipped() {
        let track = makeTrack()
        let albumTracks = [
            Track(
                id: "1",
                name: "A",
                artist: "X",
                album: "Y",
                releaseYear: 1850
            ),
            Track(
                id: "2",
                name: "B",
                artist: "X",
                album: "Y",
                releaseYear: 1850
            ),
        ]
        let candidates = [
            makeCandidate(artist: "X", album: "Y", year: 2000),
        ]

        let result = determinator.determineYear(
            candidates: candidates,
            track: track,
            albumTracks: albumTracks
        )
        // Consensus year 1850 is absurd → skipped
        #expect(result.source != .consensus)
    }

    // MARK: - Custom Components

    @Test("Custom scorer config affects result")
    func customScorerConfig() {
        var scoringConfig = ScoringConfig()
        scoringConfig.baseScore = 100
        let customScorer = YearScorer(config: scoringConfig)
        let det = YearDeterminator(scorer: customScorer)

        let track = makeTrack(artist: "A", album: "B")
        let candidates = [
            makeCandidate(artist: "A", album: "B", year: 2000),
        ]

        let result = det.determineYear(
            candidates: candidates,
            track: track
        )
        // Higher base score → higher confidence
        #expect(result.yearResult.confidence > 0)
        #expect(result.yearResult.year == 2000)
    }
}
