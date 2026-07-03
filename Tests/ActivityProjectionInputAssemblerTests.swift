import Core
import Foundation
import Services
import Testing
@testable import Genre_Updater

@Suite("ActivityProjectionInputAssembler")
struct ActivityProjectionInputAssemblerTests {
    @Test("permission denied load error maps to permissionDenied library state")
    func permissionDeniedLoadErrorMapsToPermissionDeniedLibraryState() {
        let input = ActivityProjectionInputAssembler.makeInput(from: makeContext(
            loadError: .permissionDenied,
            isLoading: false
        ))

        #expect(input.libraryState == .permissionDenied(LibraryLoadError.permissionDenied.message))
    }

    @Test("failed load error maps to failed library state")
    func failedLoadErrorMapsToFailedLibraryState() {
        let input = ActivityProjectionInputAssembler.makeInput(from: makeContext(
            loadError: .failed("Music.app is unavailable"),
            isLoading: false
        ))

        #expect(input.libraryState == .failed("Music.app is unavailable"))
    }

    @Test("loading with no error maps to loading library state")
    func loadingWithNoErrorMapsToLoadingLibraryState() {
        let input = ActivityProjectionInputAssembler.makeInput(from: makeContext(
            loadError: nil,
            isLoading: true
        ))

        #expect(input.libraryState == .loading)
    }

    @Test("no error and not loading maps to empty or ready by track count")
    func noErrorAndNotLoadingMapsToEmptyOrReadyByTrackCount() {
        let emptyInput = ActivityProjectionInputAssembler.makeInput(from: makeContext(
            tracks: [],
            loadError: nil,
            isLoading: false
        ))
        let readyInput = ActivityProjectionInputAssembler.makeInput(from: makeContext(
            tracks: [track(id: "1")],
            loadError: nil,
            isLoading: false
        ))

        #expect(emptyInput.libraryState == .empty)
        #expect(readyInput.libraryState == .ready)
    }

    private func track(id: String) -> Core.Track {
        Core.Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
    }

    private func makeContext(
        tracks: [Core.Track] = [],
        loadError: LibraryLoadError?,
        isLoading: Bool
    ) -> ActivityProjectionAssemblyContext {
        ActivityProjectionAssemblyContext(
            tracks: tracks,
            metricsSnapshot: nil,
            lastScanDate: nil,
            loadError: loadError,
            isLoading: isLoading,
            isDryRun: false,
            workflow: .empty,
            pendingVerification: nil,
            runLifecycle: nil,
            isLibrarySyncAvailable: true,
            isAutoSyncRunning: false,
            now: Date(timeIntervalSince1970: 100)
        )
    }
}
