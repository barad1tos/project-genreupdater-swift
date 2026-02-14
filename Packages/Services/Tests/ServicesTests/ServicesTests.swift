import Testing
@testable import Services

@Suite("Services Package — Phase 1 Smoke Tests")
struct ServicesSmokeTests {
    @Test("InputSanitizer strips shell metacharacters")
    func sanitizerBasic() {
        let sanitized = InputSanitizer.sanitizeForAppleScript("test; rm -rf /")
        #expect(!sanitized.contains(";"))
    }
}
