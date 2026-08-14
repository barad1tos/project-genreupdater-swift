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
        try loaded.save(to: configURL)
        let reloaded = try AppConfiguration.load(from: configURL)

        #expect(reloaded.genreUpdate.batchSize == 37)
        #expect(reloaded.genreUpdate.concurrentLimit == 4)
        #expect(reloaded.genreUpdate.overrideExisting == false)
    }

    @Test("Persisted genre override choice remains enabled after relaunch")
    func genreOverridePersists() throws {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("genreupdater-genre-override-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: configURL) }
        var config = AppConfiguration()
        config.genreUpdate.overrideExisting = true
        try config.save(to: configURL)

        let reloaded = try AppConfiguration.load(from: configURL)

        #expect(reloaded.genreUpdate.overrideExisting)
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
