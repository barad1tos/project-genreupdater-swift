import Core
import Foundation
import Services
import Testing

@Suite("PreviewRunOptions")
struct PreviewRunOptionsTests {
    @Test("preview options preserve selected genre and year flags")
    func preservesGenreAndYearFlags() {
        let options = PreviewRunOptions.make(
            configuration: AppConfiguration(),
            updateGenre: false,
            updateYear: true
        )

        #expect(options.updateGenre == false)
        #expect(options.updateYear == true)
    }

    @Test("preview options pin write and cleanup knobs off")
    func pinsWriteAndCleanupOff() {
        let options = PreviewRunOptions.make(
            configuration: AppConfiguration(),
            updateGenre: true,
            updateYear: true
        )

        #expect(options.repairExistingGenreMismatches == false)
        #expect(options.forceYearLookup == false)
        #expect(options.cleanTrackNames == false)
        #expect(options.cleanAlbumNames == false)
        #expect(options.autoAccept == false)
    }

    @Test("configuration snapshot never restores write authority")
    func snapshotDisablesWriteAuthority() {
        let snapshot = FixPlanConfigurationSnapshot.capture(
            options: UpdateOptions(updateGenre: false, minConfidence: 73, autoAccept: true),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.determinationOptions.updateGenre == false)
        #expect(snapshot.determinationOptions.minConfidence == 73)
        #expect(snapshot.determinationOptions.autoAccept == false)
    }

    @Test(
        "min confidence matches MainView clamp semantics",
        arguments: [
            (configured: 30.0, expected: 30),
            (configured: 57.0, expected: 57),
            (configured: 10.0, expected: 30),
            (configured: 250.0, expected: 100),
        ]
    )
    func clampsMinConfidence(configured: Double, expected: Int) {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = configured

        let options = PreviewRunOptions.make(
            configuration: configuration,
            updateGenre: true,
            updateYear: true
        )

        #expect(options.minConfidence == expected)
    }

    @Test("produced options have stable configuration fingerprints")
    func keepsStableFingerprints() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 85
        let first = PreviewRunOptions.make(configuration: configuration, updateGenre: true, updateYear: false)
        let second = PreviewRunOptions.make(configuration: configuration, updateGenre: true, updateYear: false)
        let capturedAt = Date(timeIntervalSince1970: 100)

        let firstFingerprint = FixPlanConfigurationSnapshot.capture(options: first, capturedAt: capturedAt).fingerprint
        let secondFingerprint = FixPlanConfigurationSnapshot.capture(options: second, capturedAt: capturedAt)
            .fingerprint

        #expect(firstFingerprint == secondFingerprint)
        #expect(firstFingerprint == """
        genre=true:year=false:repair=false:forceYear=false:cleanTracks=false:cleanAlbums=false:minConfidence=85
        """)
    }
}
