import Core
import Testing
@testable import Genre_Updater

@Suite("Metadata rule removal")
struct MetadataRuleRemovalTests {
    @Test("Built-in deletion requires a consequence warning")
    func shippedNeedsWarning() throws {
        let removal = try #require(
            MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: [0])
        )

        #expect(removal.requiresConfirmation)
        #expect(removal.message.contains("future previews and runs"))
        #expect(removal.message.contains("remaster"))
    }

    @Test("Custom deletion is immediate")
    func customRemovesImmediately() throws {
        let removal = try #require(
            MetadataRuleRemoval(group: .soundtracks, snapshot: ["game score"], offsets: [0])
        )

        #expect(!removal.requiresConfirmation)
    }

    @Test("Mixed deletion warns and preserves every selected value")
    func mixedKeepsSelection() throws {
        let removal = try #require(MetadataRuleRemoval(
            group: .reissues,
            snapshot: ["anniversary", "fan club edition"],
            offsets: [0, 1]
        ))

        #expect(removal.requiresConfirmation)
        #expect(removal.values == ["anniversary", "fan club edition"])
    }

    @Test("Built-in removal waits for confirmation while custom removal is immediate")
    func confirmationFlowControlsMutation() throws {
        var flow = MetadataRuleRemovalFlow()
        var removed: [String] = []
        let builtIn = try #require(
            MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: [0])
        )

        flow.request(builtIn) {
            removed.append(contentsOf: $0.values)
            return .applied
        }
        #expect(flow.pending == builtIn)
        #expect(removed.isEmpty)

        flow.cancel()
        #expect(flow.pending == nil)
        #expect(removed.isEmpty)

        flow.request(builtIn) {
            removed.append(contentsOf: $0.values)
            return .applied
        }
        flow.confirm(builtIn) {
            removed.append(contentsOf: $0.values)
            return .applied
        }
        #expect(flow.pending == nil)
        #expect(removed == ["remaster"])

        let custom = try #require(MetadataRuleRemoval(
            group: .editionMarkers,
            snapshot: ["fan club edition"],
            offsets: [0]
        ))
        flow.request(custom) {
            removed.append(contentsOf: $0.values)
            return .applied
        }
        #expect(flow.pending == nil)
        #expect(removed == ["remaster", "fan club edition"])
    }

    @Test("Stale confirmation surfaces a retry message")
    func staleShowsRetry() throws {
        var flow = MetadataRuleRemovalFlow()
        let removal = try #require(
            MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: [0])
        )

        flow.request(removal) { _ in .applied }
        flow.confirm(removal) { _ in .stale }

        #expect(flow.pending == nil)
        #expect(flow.failureMessage?.contains("try again") == true)
    }

    @Test("Unavailable persistence reports a save failure")
    func saveFailureMessage() throws {
        var flow = MetadataRuleRemovalFlow()
        let removal = try #require(
            MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: [0])
        )

        flow.request(removal) { _ in .applied }
        flow.confirm(removal) { _ in RuleRemovalOutcome(status: .temporaryUnavailable) }

        #expect(flow.pending == nil)
        #expect(flow.failureMessage?.contains("could not be saved") == true)
        #expect(flow.failureMessage?.contains("Nothing was changed") == true)
    }

    @Test("Invalid settings revision requires configuration recovery")
    func revisionRecoveryMessage() throws {
        var flow = MetadataRuleRemovalFlow()
        let removal = try #require(
            MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: [0])
        )

        flow.request(removal) { _ in .applied }
        flow.confirm(removal) { _ in RuleRemovalOutcome(status: .requiresAttention) }

        #expect(flow.pending == nil)
        #expect(flow.failureMessage?.contains(AppConfiguration.configFileURL.path) == true)
        #expect(flow.failureMessage?.contains("set \"revision\" to 0") == true)
        #expect(flow.failureMessage?.contains("relaunch GenreUpdater") == true)
        #expect(flow.failureMessage?.localizedCaseInsensitiveContains("reset") == false)
        #expect(flow.failureMessage?.contains("try again") == false)
    }

    @Test("Every built-in group explains its consequence")
    func groupsExplainConsequences() throws {
        let expectedPhrases: [MetadataRuleGroup: String] = [
            .editionMarkers: "track and album names",
            .albumSuffixes: "album suffixes",
            .specialAlbums: "special albums",
            .compilations: "compilation-specific",
            .reissues: "reissue-specific",
            .soundtracks: "soundtrack-specific lookup and scoring",
            .variousArtists: "Various Artists search strategy",
        ]
        for group in MetadataRuleGroup.allCases {
            let value = try #require(MetadataRuleDefaults.values(for: group).first)
            let phrase = try #require(expectedPhrases[group])
            let removal = try #require(MetadataRuleRemoval(group: group, snapshot: [value], offsets: [0]))

            #expect(removal.requiresConfirmation)
            #expect(removal.message.contains(phrase))
        }
    }

    @Test("Removal identity preserves duplicate occurrences and list snapshot")
    func duplicateOccurrencesStayDistinct() throws {
        let removal = try #require(MetadataRuleRemoval(
            group: .editionMarkers,
            snapshot: ["remaster", "custom", "remaster"],
            offsets: [2]
        ))

        #expect(removal.values == ["remaster"])
        #expect(removal.offsets == [2])
        #expect(removal.snapshot == ["remaster", "custom", "remaster"])
        #expect(removal.removing(from: removal.snapshot) == ["remaster", "custom"])
        #expect(removal.removing(from: ["remaster", "changed", "remaster"]) == nil)
    }

    @Test("Empty and stale offsets cannot create a removal intent")
    func invalidOffsetsAreRejected() {
        #expect(MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: []) == nil)
        #expect(MetadataRuleRemoval(group: .editionMarkers, snapshot: ["remaster"], offsets: [1]) == nil)
    }

    @Test("Every rule group removes from its persisted configuration list", arguments: MetadataRuleGroup.allCases)
    func groupTargetsList(_ group: MetadataRuleGroup) throws {
        let configuration = AppConfiguration()
        let snapshot = MetadataRuleDefaults.values(for: group)
        let removal = try #require(MetadataRuleRemoval(group: group, snapshot: snapshot, offsets: [0]))

        let updated = try #require(removal.removing(from: configuration))

        #expect(rules(for: group, in: updated) == Array(snapshot.dropFirst()))
    }

    private func rules(for group: MetadataRuleGroup, in configuration: AppConfiguration) -> [String] {
        switch group {
        case .editionMarkers: configuration.cleaning.editionMarkers
        case .albumSuffixes: configuration.cleaning.albumSuffixes
        case .specialAlbums: configuration.albumTypeDetection.specialPatterns
        case .compilations: configuration.albumTypeDetection.compilationPatterns
        case .reissues: configuration.albumTypeDetection.reissuePatterns
        case .soundtracks: configuration.albumTypeDetection.soundtrackPatterns
        case .variousArtists: configuration.albumTypeDetection.variousArtistsNames
        }
    }
}
