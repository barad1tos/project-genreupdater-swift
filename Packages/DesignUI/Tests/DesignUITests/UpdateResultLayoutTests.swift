import Testing
@testable import DesignUI

@Suite("Shared update result layout")
struct UpdateResultLayoutTests {
    @Test("preview and write render the same stable section order")
    func sharesSectionOrder() {
        let expected: [UpdateResultSection] = [.status, .metrics, .albums, .details, .actions]

        #expect(UpdateResultSection.order(for: .preview) == expected)
        #expect(UpdateResultSection.order(for: .write) == expected)
    }
}
