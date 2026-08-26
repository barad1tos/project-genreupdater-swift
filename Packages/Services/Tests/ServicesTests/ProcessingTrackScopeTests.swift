import Testing
@testable import Services

@Suite("Processing track scope")
struct ProcessingTrackScopeTests {
    @Test("Scope normalizes test artists")
    func scopeNormalizesTestArtists() {
        let request = ProcessingTrackScope(testArtists: [" Metallica ", "", "Radiohead"])

        #expect(request.testArtists == ["Metallica", "Radiohead"])
    }
}
