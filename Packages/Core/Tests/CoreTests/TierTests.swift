import Testing
@testable import Core

@Suite("Tier — ordering and properties")
struct TierTests {
    @Test("Tier ordering: free < weekPass < pro")
    func ordering() {
        #expect(Tier.free < Tier.weekPass)
        #expect(Tier.weekPass < Tier.pro)
        #expect(Tier.free < Tier.pro)
    }

    @Test("Equal tiers are not less-than")
    func equality() {
        let free = Tier.free
        let sameFree = Tier.free
        let pro = Tier.pro
        let samePro = Tier.pro

        #expect(!(free < sameFree))
        #expect(!(pro < samePro))
    }

    @Test("Tier conforms to CaseIterable with 3 cases")
    func caseCount() {
        #expect(Tier.allCases.count == 3)
        #expect(Tier.allCases == [.free, .weekPass, .pro])
    }

    @Test("Raw values are sequential integers")
    func rawValues() {
        #expect(Tier.free.rawValue == 0)
        #expect(Tier.weekPass.rawValue == 1)
        #expect(Tier.pro.rawValue == 2)
    }
}
