import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("LibraryLoadError")
struct LibraryLoadErrorTests {
    @Test("mapper preserves authorization state")
    func mapperPreservesAuthorizationState() {
        #expect(LibraryLoadError.make(from: MusicLibraryError.authorizationDenied) == .permissionDenied)
        #expect(LibraryLoadError.make(from: MusicLibraryError.authorizationRestricted) == .restricted)
    }

    @Test("mapper preserves failure detail")
    func mapperPreservesFailureDetail() {
        #expect(LibraryLoadError.make(from: MusicLibraryError.fetchFailed(detail: "timeout"))
            .message == "Failed to read music library: timeout")
        #expect(LibraryLoadError.make(from: MusicLibraryError.musicAppNotAvailable)
            .message == "Music app is not available on this system.")
    }

    @Test("mapper handles generic errors")
    func mapperHandlesGenericErrors() {
        #expect(LibraryLoadError.make(from: GenericLibraryLoadError()).message == "generic failure")
    }
}

private struct GenericLibraryLoadError: LocalizedError {
    var errorDescription: String? {
        "generic failure"
    }
}
