import Testing
@testable import DesignUI

@Suite("Navigation history")
struct NavigationHistoryTests {
    @Test
    func routeNavigationSupportsBackAndForward() {
        let model = AppModel()

        #expect(model.route == .activity)
        #expect(!model.canNavigateBack)
        #expect(!model.canNavigateForward)

        model.navigate(to: .update)

        #expect(model.route == .update)
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)

        model.navigateBack()

        #expect(model.route == .activity)
        #expect(!model.canNavigateBack)
        #expect(model.canNavigateForward)

        model.navigateForward()

        #expect(model.route == .update)
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)
    }

    @Test
    func browseNavigationRestoresFilter() {
        let model = AppModel()

        model.openBrowse(filter: .missingGenre)
        model.navigate(to: .update)
        model.navigateBack()

        #expect(model.route == .browse)
        #expect(model.browseFilter == .missingGenre)
    }

    @Test
    func duplicateNavigationDoesNotCreateHistory() {
        let model = AppModel()

        model.navigate(to: .activity)

        #expect(model.route == .activity)
        #expect(!model.canNavigateBack)
    }

    @Test
    func newNavigationClearsForwardHistory() {
        let model = AppModel()

        model.navigate(to: .update)
        model.navigateBack()
        model.navigate(to: .reports)

        #expect(model.route == .reports)
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)
    }
}
