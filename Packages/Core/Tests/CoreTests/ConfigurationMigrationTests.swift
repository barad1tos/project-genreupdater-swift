import Foundation
import Testing
@testable import Core

@Suite("Configuration migration")
struct ConfigurationMigrationTests {
    @Test("Configuration saved before genre override existed still loads")
    func legacyGenreLoads() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-legacy-genre-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let json = Data(#"{"genreUpdate":{"batchSize":37,"concurrentLimit":4}}"#.utf8)
        try json.write(to: configURL, options: .atomic)

        let loaded = try AppConfiguration.load(from: configURL)

        #expect(loaded.genreUpdate.batchSize == 37)
        #expect(loaded.genreUpdate.concurrentLimit == 4)
        #expect(loaded.genreUpdate.overrideExisting == false)
    }

    @Test("Persisted genre override choice remains enabled after relaunch")
    func genreOverrideDecodes() throws {
        let json = Data(#"{"genreUpdate":{"overrideExisting":true}}"#.utf8)

        let loaded = try JSONDecoder().decode(AppConfiguration.self, from: json)

        #expect(loaded.genreUpdate.overrideExisting)
    }

    @Test("Released remasterKeywords custom values survive load save and reload")
    func keepsCustomLegacy() throws {
        try assertLegacyValues(["promo", "expanded edition"])
    }

    @Test("Released remasterKeywords empty value survives load save and reload")
    func keepsEmptyLegacy() throws {
        try assertLegacyValues([])
    }

    private func assertLegacyValues(_ keywords: [String]) throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-legacy-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        let keywordData = try JSONEncoder().encode(keywords)
        let keywordJSON = try #require(String(data: keywordData, encoding: .utf8))
        let legacyJSON = #"{"cleaning":{"remasterKeywords":\#(keywordJSON)}}"#
        try Data(legacyJSON.utf8).write(to: configURL, options: .atomic)

        let loaded = try AppConfiguration.load(from: configURL)
        try loaded.save(to: configURL)
        let reloaded = try AppConfiguration.load(from: configURL)

        #expect(loaded.cleaning.editionMarkers == keywords)
        #expect(reloaded.cleaning.editionMarkers == keywords)
    }
}
