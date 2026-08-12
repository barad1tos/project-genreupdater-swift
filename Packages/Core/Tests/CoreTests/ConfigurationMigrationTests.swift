import Foundation
import Testing
@testable import Core

@Suite("Configuration migration")
struct ConfigurationMigrationTests {
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
