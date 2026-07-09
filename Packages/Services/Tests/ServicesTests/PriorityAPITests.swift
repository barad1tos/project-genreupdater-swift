import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("APIOrchestrator — source priority configuration")
struct PriorityAPITests {
    @Test("Default script API priority applies without script override")
    func defaultScriptAPIPriorityAppliesWithoutScriptOverride() async {
        let orchestrator = makeAPIOrchestrator(
            musicBrainz: MockAPIService(
                yearResult: YearResult(year: 2000, confidence: 60, yearScores: [2000: 60])
            ),
            discogs: MockAPIService(
                yearResult: YearResult(year: 2001, confidence: 60, yearScores: [2001: 60])
            ),
            appleMusic: MockAPIService()
        ) {
            $0.sourcePriorityConfiguration = APISourcePriorityConfiguration(
                preferredAPI: .musicbrainz,
                scriptPriorities: [
                    "default": ScriptAPIPriority(primary: ["discogs"], fallback: ["musicbrainz"]),
                ]
            )
        }

        let result = await orchestrator.getAlbumYear(
            artist: "Pink Floyd",
            album: "Animals",
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )

        #expect(result.year == 2001)
        #expect(result.confidence == 60)
    }
}
