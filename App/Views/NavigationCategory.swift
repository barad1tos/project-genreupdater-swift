// NavigationCategory.swift — sidebar taxonomy and keyboard-shortcut focus wiring.

import SwiftUI

enum NavigationCategory: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case browse = "Browse"
    case reports = "Reports"
    case update = "Update"

    var id: String {
        rawValue
    }

    static var allInOrder: [Self] {
        [.dashboard, .browse, .reports, .update]
    }
}

// MARK: - Focused Value (Keyboard Shortcut Wiring)

struct FocusedCategoryKey: FocusedValueKey {
    typealias Value = Binding<NavigationCategory?>
}

extension FocusedValues {
    var selectedCategory: Binding<NavigationCategory?>? {
        get { self[FocusedCategoryKey.self] }
        set { self[FocusedCategoryKey.self] = newValue }
    }
}
