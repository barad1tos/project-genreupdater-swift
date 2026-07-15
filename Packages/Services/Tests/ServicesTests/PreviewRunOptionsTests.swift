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
        let snapshot = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(updateGenre: false, minConfidence: 73, autoAccept: true),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.determinationOptions.updateGenre == false)
        #expect(snapshot.determinationOptions.minConfidence == 73)
        #expect(snapshot.determinationOptions.autoAccept == false)
    }

    @Test("legacy snapshots preserve their stored fingerprint")
    func decodesLegacySnapshot() throws {
        let snapshot = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(updateGenre: false, minConfidence: 73),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appConfiguration")
        object["fingerprint"] = "legacy-fingerprint"

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FixPlanConfig.self, from: legacyData)

        #expect(decoded.fingerprint == "legacy-fingerprint")
        #expect(decoded.minConfidence == 73)
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

        let firstFingerprint = FixPlanConfig.capture(
            configuration: configuration,
            options: first,
            capturedAt: capturedAt
        ).fingerprint
        let secondFingerprint = FixPlanConfig.capture(
            configuration: configuration,
            options: second,
            capturedAt: capturedAt
        )
        .fingerprint

        #expect(firstFingerprint == secondFingerprint)
        #expect(firstFingerprint.count == 64)
    }

    @Test("determination settings change configuration fingerprints")
    func fingerprintsDeterminationSettings() {
        var first = AppConfiguration()
        var second = first
        first.cleaning.genreMappings = ["Electronic": "Electronica"]
        second.cleaning.genreMappings = ["Electronic": "IDM"]
        let options = UpdateOptions()
        let capturedAt = Date(timeIntervalSince1970: 100)

        let firstFingerprint = FixPlanConfig.capture(
            configuration: first,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        let secondFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint

        #expect(firstFingerprint != secondFingerprint)
    }

    @Test("populated configuration preserves its fingerprint through Codable")
    func populatedConfigurationRoundTrips() throws {
        var configuration = AppConfiguration()
        configuration.cleaning.genreMappings = ["Electronic": "Electronica"]
        configuration.processing.batchSize = 17
        let snapshot = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(minConfidence: 73),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FixPlanConfig.self, from: data)

        #expect(decoded.fingerprint == snapshot.fingerprint)
        #expect(decoded.appConfiguration.cleaning.genreMappings == ["Electronic": "Electronica"])
        #expect(decoded.appConfiguration.processing.batchSize == 17)
    }
}
