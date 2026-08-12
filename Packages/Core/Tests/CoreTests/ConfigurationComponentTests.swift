import Foundation
import Testing
@testable import Core

@Suite("Configuration components")
struct ConfigurationComponentTests {
    @Test(
        "PreferredAPI all cases encode and decode via rawValue",
        arguments: PreferredAPI.allCases
    )
    func preferredAPIRoundTrip(api: PreferredAPI) throws {
        let data = try JSONEncoder().encode(api)
        let decoded = try JSONDecoder().decode(PreferredAPI.self, from: data)
        #expect(decoded == api)
    }

    @Test("PreferredAPI rawValues match expected strings")
    func preferredAPIRawValues() {
        #expect(PreferredAPI.musicbrainz.rawValue == "musicbrainz")
        #expect(PreferredAPI.discogs.rawValue == "discogs")
        #expect(PreferredAPI.itunes.rawValue == "itunes")
    }

    @Test("ScoringConfig default values")
    func scoringDefaults() {
        let scoring = ScoringConfig()

        #expect(scoring.baseScore == 10)
        #expect(scoring.artistExactMatchBonus == 20)
        #expect(scoring.albumExactMatchBonus == 25)
        #expect(scoring.perfectMatchBonus == 10)
        #expect(scoring.mbReleaseGroupMatchBonus == 50)
        #expect(scoring.sourceMBBonus == 25)
        #expect(scoring.sourceITunesBonus == -10)
    }

    @Test("CleaningConfig uses centralized edition markers")
    func cleaningUsesEditionDefaults() {
        let cleaning = CleaningConfig()
        #expect(cleaning.editionMarkers == MetadataRuleDefaults.editionMarkers)
    }

    @Test("CleaningConfig includes bare edition suffixes")
    func cleaningAlbumSuffixesCount() {
        let cleaning = CleaningConfig()
        #expect(Set(cleaning.albumSuffixes) == [
            "Expanded Edition",
            "Remaster",
            "Remastered",
            "Reissue",
            "The 12 Singles",
            "The 12\" Singles",
        ])
    }

    @Test("Legacy suffixes preserve the user's stored selection")
    func legacySuffixesRemain() throws {
        let json = Data(#"{"albumSuffixesToRemove":["Remaster","Remastered","The 12 Singles","The 12\" Singles"]}"#
            .utf8)

        let cleaning = try JSONDecoder().decode(CleaningConfig.self, from: json)

        #expect(cleaning.albumSuffixes == [
            "Remaster", "Remastered", "The 12 Singles", "The 12\" Singles",
        ])
    }

    @Test("Customized legacy suffixes remain unchanged")
    func customSuffixesRemain() throws {
        let json = Data(#"{"albumSuffixesToRemove":["Remaster","Fan Club Edition"]}"#.utf8)

        let cleaning = try JSONDecoder().decode(CleaningConfig.self, from: json)

        #expect(cleaning.albumSuffixes == ["Remaster", "Fan Club Edition"])
    }

    @Test("CleaningConfig default trackCleaningExceptions is empty")
    func cleaningExceptionsEmpty() {
        let cleaning = CleaningConfig()
        #expect(cleaning.trackCleaningExceptions.isEmpty)
    }

    @Test("CleaningConfig default genreMappings is empty")
    func cleaningGenreMappingsEmpty() {
        let cleaning = CleaningConfig()
        #expect(cleaning.genreMappings.isEmpty)
    }

    @Test("CleaningConfig genreMappings round-trip preserves entries")
    func cleaningGenreMappingsRoundTrip() throws {
        var cleaning = CleaningConfig()
        cleaning.genreMappings = [
            "Electronica": "Electronic",
            "Hip Hop": "Hip-Hop",
        ]
        let data = try JSONEncoder().encode(cleaning)
        let decoded = try JSONDecoder().decode(CleaningConfig.self, from: data)
        #expect(decoded.genreMappings == ["Electronica": "Electronic", "Hip Hop": "Hip-Hop"])
    }

    @Test("ScriptAPIPriority with primary only leaves fallback empty")
    func scriptAPIPriorityPrimaryOnly() {
        let priority = ScriptAPIPriority(primary: ["musicbrainz"])

        #expect(priority.primary == ["musicbrainz"])
        #expect(priority.fallback.isEmpty)
    }

    @Test("ScriptAPIPriority with both primary and fallback")
    func scriptAPIPriorityBoth() {
        let priority = ScriptAPIPriority(primary: ["musicbrainz"], fallback: ["discogs"])

        #expect(priority.primary == ["musicbrainz"])
        #expect(priority.fallback == ["discogs"])
    }

    @Test("TrackCleaningException round-trip preserves fields")
    func trackCleaningExceptionRoundTrip() throws {
        let original = TrackCleaningException(artist: "Pink Floyd", album: "The Wall")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrackCleaningException.self, from: data)

        #expect(decoded.artist == "Pink Floyd")
        #expect(decoded.album == "The Wall")
    }
}
