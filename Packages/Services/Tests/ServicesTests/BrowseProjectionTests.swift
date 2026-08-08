import Foundation
import Services
import Testing

@Suite("Browse projection type")
struct BrowseProjectionTests {
    @Test("a preview request carries its browse target")
    func previewRequestCarriesTarget() {
        let target = BrowseCommandTarget(
            albumID: "album-key",
            projectionRevision: .initial,
            scopeSnapshotID: UUID()
        )
        let command = UserIntentCommand.requestAlbumPreview(target: target)

        #expect(command.kind == .requestAlbumPreview)
        #expect(command.browseTarget == target)
        #expect(command.fixPlanTarget == nil)
    }
}
