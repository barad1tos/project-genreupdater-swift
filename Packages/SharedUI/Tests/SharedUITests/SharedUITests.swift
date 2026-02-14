import Testing
@testable import SharedUI

@Suite("SharedUI Package — Phase 1 Smoke Tests")
struct SharedUISmokeTests {
    @Test("SharedUI module version is set")
    func moduleVersion() {
        #expect(SharedUIModule.version == "1.0.0")
    }
}
