import CryptoKit
import Foundation
import Testing

/// The parity fixtures are this port's only evidence that Swift decides what
/// Python decides. That evidence is only worth something if a fixture cannot
/// be quietly edited to match Swift — which is exactly how a real 50-point
/// artist-scoring divergence survived every gate until slice 17.
///
/// This suite pins each fixture file's content digest and its provenance
/// split. Changing an expectation now fails here, so the change has to be
/// argued rather than absorbed.
@Suite("Fixture provenance — parity evidence cannot drift silently")
struct FixtureProvenanceTests {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let digest: String
            let caseCount: Int?
            let generated: Int?
            let verifiedByExecution: Int?
        }

        let files: [String: Entry]
    }

    @Test("every fixture matches its recorded digest and case count")
    func fixturesMatchManifest() throws {
        let manifest = try loadManifest()

        for (name, entry) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let url = try fixtureURL(named: name)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let canonical = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            let digest = "sha256:" + SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()

            #expect(
                digest == entry.digest,
                """
                [\(name)] content changed. If the change is intentional, re-derive the \
                expectations from Python and record the new digest \(digest) in \
                fixtures_manifest.json — never edit an expectation to make a test pass.
                """
            )

            if let expectedCount = entry.caseCount {
                let cases = try #require(object as? [Any])
                #expect(cases.count == expectedCount, "[\(name)] case count changed")
                #expect(
                    (entry.generated ?? 0) + (entry.verifiedByExecution ?? 0) == expectedCount,
                    "[\(name)] provenance split does not add up to the case count"
                )
            }
        }
    }

    @Test("every fixture case carries a unique id")
    func fixtureCaseIDsAreUnique() throws {
        let manifest = try loadManifest()

        for (name, entry) in manifest.files where entry.caseCount != nil {
            let url = try fixtureURL(named: name)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            let cases = try #require(object as? [[String: Any]])
            let identifiers = cases.compactMap { $0["id"] as? String }

            #expect(identifiers.count == cases.count, "[\(name)] a case is missing its id")
            #expect(Set(identifiers).count == identifiers.count, "[\(name)] duplicate case id")
        }
    }

    private func loadManifest() throws -> Manifest {
        let url = try fixtureURL(named: "fixtures_manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
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
