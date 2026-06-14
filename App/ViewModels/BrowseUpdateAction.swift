// BrowseUpdateAction.swift -- typed Browse bulk action notifications.

import Foundation

enum BrowseUpdateAction: String, CaseIterable {
    case genres
    case years
    case dryRun

    static let actionUserInfoKey = "action"
    static let selectedItemsUserInfoKey = "items"

    var title: String {
        switch self {
        case .genres:
            "Update Genres"
        case .years:
            "Update Years"
        case .dryRun:
            "Dry Run"
        }
    }

    var iconName: String {
        switch self {
        case .genres:
            "tag"
        case .years:
            "calendar"
        case .dryRun:
            "eye"
        }
    }

    func post(selectedItems: Set<String>) {
        NotificationCenter.default.post(
            name: .browseAction,
            object: nil,
            userInfo: [
                Self.actionUserInfoKey: rawValue,
                Self.selectedItemsUserInfoKey: selectedItems,
            ]
        )
    }
}

struct BrowseUpdateRequest {
    let action: BrowseUpdateAction
    let selectedItems: Set<String>

    init?(notification: Notification) {
        guard let actionName = notification.userInfo?[BrowseUpdateAction.actionUserInfoKey] as? String,
              let action = BrowseUpdateAction(rawValue: actionName)
        else { return nil }

        self.action = action
        if let selectedItems = notification.userInfo?[BrowseUpdateAction.selectedItemsUserInfoKey] as? Set<String> {
            self.selectedItems = selectedItems
        } else if let selectedItems = notification.userInfo?[BrowseUpdateAction.selectedItemsUserInfoKey] as? [String] {
            self.selectedItems = Set(selectedItems)
        } else {
            selectedItems = []
        }
    }
}
