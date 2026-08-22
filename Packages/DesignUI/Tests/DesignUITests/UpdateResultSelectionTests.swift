import Testing
@testable import DesignUI

@Suite("Shared update result selection")
struct UpdateResultSelectionTests {
    @Test("selection stays on a visible album and otherwise chooses the first")
    func reconcilesSelection() {
        let albums = [makeAlbum(id: "a"), makeAlbum(id: "b")]

        #expect(UpdateResultSelection.resolve(currentID: "b", albums: albums) == "b")
        #expect(UpdateResultSelection.resolve(currentID: "missing", albums: albums) == "a")
        #expect(UpdateResultSelection.resolve(currentID: "a", albums: []) == nil)
    }

    private func makeAlbum(id: String) -> UpdateResultAlbum {
        UpdateResultAlbum(id: id, title: "Album \(id)", tracks: [])
    }
}
