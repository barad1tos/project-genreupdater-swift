// NavigationCategory.swift — sidebar taxonomy and keyboard-shortcut focus wiring.

import SwiftUI

enum NavigationCategory: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case browse = "Browse"
    case reports = "Reports"
    case analytics = "Analytics"
    case update = "Update"

    var id: String {
        rawValue
    }

    static func visibleOrder(isAdvancedExperience: Bool) -> [Self] {
        isAdvancedExperience
            ? [.dashboard, .browse, .reports, .analytics, .update]
            : [.dashboard, .browse, .reports, .update]
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
