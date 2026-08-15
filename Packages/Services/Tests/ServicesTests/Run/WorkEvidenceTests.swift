import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Work evidence")
struct WorkEvidenceTests {
    @Test("Current write-adjacent construction captures the planned effect")
    func capturesWriteEvidence() {
        let states: [WorkState] = [.attempting, .attempted, .outcome(.written)]

        for state in states {
            let item = makeWorkItem(state: state)
            #expect(item.writeChange == item.change)
        }
    }

    @Test("Legacy write-adjacent payloads still decode without evidence")
    func legacyStateDecodes() throws {
        let current = makeWorkItem(state: .attempted)
        var payload = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        payload.removeValue(forKey: "writeChange")

        let legacy = try JSONDecoder().decode(
            RunWorkItem.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(legacy.state == .attempted)
        #expect(legacy.writeChange == nil)
        #expect(legacy.effectiveChange == legacy.change)
    }

    @Test("Persisted plans reject album artist evidence on unrelated changes")
    func rejectsMalformedPlan() throws {
        let item = makeWorkItem(state: .prepared)
        var payload = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        var change = try #require(payload["change"] as? [String: Any])
        change["albumArtistChange"] = ["oldValue": "Rock", "newValue": "Metal"]
        payload["change"] = change

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RunWorkItem.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )
        }
    }

    @Test("Persisted writes reject a contradictory album artist source")
    func rejectsMalformedWrite() throws {
        let item = makeWorkItem(
            state: .attempted,
            changeType: .artistRename,
            oldValue: "Massive",
            newValue: "Massive Attack",
            albumArtistChange: AlbumArtistChange(
                oldValue: "Massive",
                newValue: "Massive Attack"
            )
        )
        var payload = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any]
        )
        var writeChange = try #require(payload["writeChange"] as? [String: Any])
        writeChange["albumArtistChange"] = [
            "oldValue": "Various Artists",
            "newValue": "Massive Attack",
        ]
        payload["writeChange"] = writeChange

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RunWorkItem.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )
        }
    }
}
