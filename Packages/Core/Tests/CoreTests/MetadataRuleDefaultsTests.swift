import Testing
@testable import Core

@Suite("Metadata rule defaults")
struct MetadataRuleDefaultsTests {
    @Test("Every configurable group has shipped rules")
    func groupsHaveDefaults() {
        for group in MetadataRuleGroup.allCases {
            #expect(!MetadataRuleDefaults.values(for: group).isEmpty)
        }
    }

    @Test("Built-in lookup ignores case and surrounding whitespace")
    func lookupNormalizes() {
        #expect(MetadataRuleDefaults.contains("  REMASTER  ", in: .editionMarkers))
        #expect(MetadataRuleDefaults.contains(" ost ", in: .soundtracks))
        #expect(!MetadataRuleDefaults.contains("fan club edition", in: .editionMarkers))
    }

    @Test("Cleaning and detection keep role-specific rule sets")
    func rolesStaySeparate() {
        #expect(MetadataRuleDefaults.values(for: .editionMarkers).contains("reissue"))
        #expect(MetadataRuleDefaults.values(for: .albumSuffixes).contains("Reissue"))
        #expect(MetadataRuleDefaults.values(for: .reissues).contains("anniversary"))
        #expect(MetadataRuleDefaults.releaseReissues == ["reissue", "remaster", "remastered"])
    }
}
