// SettingsSupport.swift — shared settings bindings and display helpers.

import Core
import SharedUI
import SwiftUI

// MARK: - Update Behavior

enum UpdateBehavior: String, CaseIterable, Identifiable {
    case genreOnly = "genre_only"
    case yearOnly = "year_only"
    case both

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .genreOnly: "Genre only"
        case .yearOnly: "Year only"
        case .both: "Both"
        }
    }
}

// MARK: - JSON Editor State

enum JSONEditorState {
    case idle, valid, invalid, saved, copied

    var symbolName: String {
        switch self {
        case .idle: "curlybraces"
        case .valid: "checkmark.circle.fill"
        case .invalid: "exclamationmark.triangle.fill"
        case .saved: "checkmark.circle.fill"
        case .copied: "doc.on.doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .valid, .saved, .copied: Ayu.success
        case .invalid: Ayu.error
        }
    }
}

// MARK: - Bindings

@MainActor
func configBinding<Value>(
    _ dependencies: AppDependencies,
    _ keyPath: WritableKeyPath<AppConfiguration, Value>
) -> Binding<Value> {
    Binding(
        get: { dependencies.config[keyPath: keyPath] },
        set: { newValue in
            dependencies.config[keyPath: keyPath] = newValue
            saveConfiguration(dependencies)
        }
    )
}

@MainActor
func saveConfiguration(_ dependencies: AppDependencies) {
    try? dependencies.config.save()
    dependencies.applyRuntimeConfiguration()
}

// MARK: - Display Names

extension PreferredAPI {
    var displayName: String {
        switch self {
        case .musicbrainz: "MusicBrainz"
        case .discogs: "Discogs"
        case .itunes: "Apple Music"
        }
    }
}

extension PrereleaseHandling {
    var displayName: String {
        switch self {
        case .processEditable: "Process editable"
        case .skipAll: "Skip all"
        case .markOnly: "Mark only"
        }
    }
}

extension ChangeDisplayMode {
    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .detailed: "Detailed"
        }
    }
}
