import Foundation
import Testing
@testable import Core

@Suite("AppleScript timeouts")
struct AppleScriptTimeoutsTests {
    @Test("Duration values encode as seconds with suffixed keys")
    func encodesAsSeconds() throws {
        let timeouts = AppleScriptTimeouts()
        let data = try JSONEncoder().encode(timeouts)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["defaultTimeoutSeconds"] as? Int == 3600)
        #expect(json["fullLibraryFetchSeconds"] as? Int == 3600)
        #expect(json["singleArtistFetchSeconds"] as? Int == 600)
        #expect(json["batchUpdateSeconds"] as? Int == 1800)
        #expect(json["idsBatchFetchSeconds"] as? Int == 120)
    }

    @Test("Empty JSON uses every default")
    func decodesDefaults() throws {
        let timeouts = try JSONDecoder().decode(AppleScriptTimeouts.self, from: Data("{}".utf8))

        #expect(timeouts.defaultTimeout == .seconds(3600))
        #expect(timeouts.fullLibraryFetch == .seconds(3600))
        #expect(timeouts.singleArtistFetch == .seconds(600))
        #expect(timeouts.batchUpdate == .seconds(1800))
        #expect(timeouts.idsBatchFetch == .seconds(120))
    }

    @Test("Partial JSON applies defaults for missing keys")
    func decodesPartialValues() throws {
        let json = Data(#"{"defaultTimeoutSeconds":100}"#.utf8)
        let timeouts = try JSONDecoder().decode(AppleScriptTimeouts.self, from: json)

        #expect(timeouts.defaultTimeout == .seconds(100))
        #expect(timeouts.fullLibraryFetch == .seconds(3600))
        #expect(timeouts.singleArtistFetch == .seconds(600))
        #expect(timeouts.batchUpdate == .seconds(1800))
        #expect(timeouts.idsBatchFetch == .seconds(120))
    }
}
