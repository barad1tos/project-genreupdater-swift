import CryptoKit
import Foundation
import Testing

@Suite("Provider fixture provenance")
struct ProviderFixtureProvenanceTests {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let digest: String
            let caseCount: Int
            let generated: Int
            let verifiedByExecution: Int
        }

        let files: [String: Entry]
    }

    @Test("manifest covers every provider fixture")
    func manifestCoversFixtures() throws {
        let manifest = try loadManifest()
        let fixtureURLs = try #require(
            Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Fixtures")
        )
        let fixtureNames = Set(fixtureURLs.map(\.lastPathComponent))
            .subtracting(["fixtures_manifest.json"])

        #expect(fixtureNames == Set(manifest.files.keys))
    }

    @Test("provider fixture matches its generated digest and case count")
    func fixtureMatchesManifest() throws {
        let manifest = try loadManifest()

        for (name, entry) in manifest.files {
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtureURL(named: name))
            )
            let canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let digest = "sha256:" + SHA256.hash(data: canonical)
                .map { String(format: "%02x", $0) }
                .joined()
            let fixture = try #require(object as? [String: Any])
            let cases = try #require(fixture["cases"] as? [[String: Any]])

            #expect(digest == entry.digest, "\(name) changed without provenance refresh")
            #expect(cases.count == entry.caseCount)
            #expect(entry.generated + entry.verifiedByExecution == entry.caseCount)
        }
    }

    @Test("every provider fixture case has a unique id")
    func fixtureCaseIDsAreUnique() throws {
        let manifest = try loadManifest()

        for name in manifest.files.keys {
            let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtureURL(named: name))
            )
            let fixture = try #require(object as? [String: Any])
            let cases = try #require(fixture["cases"] as? [[String: Any]])
            let identifiers = cases.compactMap { $0["id"] as? String }

            #expect(identifiers.count == cases.count)
            #expect(Set(identifiers).count == identifiers.count)
        }
    }

    private func loadManifest() throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: fixtureURL(named: "fixtures_manifest.json"))
        )
    }

    private func fixtureURL(named name: String) throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: name.replacingOccurrences(of: ".json", with: ""),
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "missing fixture \(name)"
        )
    }
}
