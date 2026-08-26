import Testing
@testable import Core

@Suite("Mirror scope coverage")
struct MirrorCoverageTests {
    @Test("Artist scope equality ignores order casing and duplicate spelling")
    func normalizedScopeEquality() {
        let first = MirrorScope(testArtists: [" Metallica ", "BJÖRK", "metallica"])
        let second = MirrorScope(testArtists: ["björk", "metallica"])

        #expect(first == second)
    }

    @Test("Full-library coverage admits every artist scope")
    func fullLibraryAdmitsArtists() {
        let coverage = MirrorCoverage.verified(.fullLibrary)

        #expect(coverage.admits(MirrorScope(testArtists: ["Metallica"])))
        #expect(coverage.admits(.fullLibrary))
    }

    @Test("Artist coverage admits only matching artist subsets")
    func coverageAdmitsSubsets() {
        let coverage = MirrorCoverage.verified(MirrorScope(testArtists: ["Metallica", "Björk"]))

        #expect(coverage.admits(MirrorScope(testArtists: ["björk"])))
        #expect(!coverage.admits(MirrorScope(testArtists: ["Metallica", "Clutch"])))
        #expect(!coverage.admits(.fullLibrary))
    }

    @Test("Replacing verified scope discards prior artist evidence")
    func replacementDropsPriorScope() {
        let metallica = MirrorScope(testArtists: ["Metallica"])
        let bjork = MirrorScope(testArtists: ["Björk"])
        let prior = MirrorCoverage.verified(metallica)

        let replaced = prior.applying(.replace(bjork))

        #expect(replaced == .verified(bjork))
        #expect(!replaced.admits(metallica))
    }
}
