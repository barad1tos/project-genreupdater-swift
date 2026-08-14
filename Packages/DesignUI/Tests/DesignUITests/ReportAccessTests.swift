import Testing
@testable import DesignUI

@Suite("Report section access")
struct ReportAccessTests {
    @Test
    func availableAccessShowsEveryReportSection() {
        let access = ReportSectionAccess(.available)

        #expect(access.showsAnalytics)
        #expect(access.showsAudit)
        #expect(access.showsRecovery)
    }

    @Test
    func lockedAccessHidesOnlyAnalytics() {
        let access = ReportSectionAccess(.locked(message: "Upgrade"))

        #expect(!access.showsAnalytics)
        #expect(access.showsAudit)
        #expect(access.showsRecovery)
    }
}
