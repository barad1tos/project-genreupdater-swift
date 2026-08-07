// SettingsSupport.swift — shared settings bindings and display helpers.

import Core
import Services
import SharedUI
import SwiftUI

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
            mutateConfiguration(dependencies) { configuration in
                configuration[keyPath: keyPath] = newValue
            }
        }
    )
}

/// The one write path for UI settings mutations: copy-with-edit against
/// the live config, CAS target from the live revision, dispatched through
/// the command's synchronous acceptance head — the mutation is visible to
/// SwiftUI on the same render turn (controlled TextFields depend on it).
@MainActor
@discardableResult
func mutateConfiguration(
    _ dependencies: AppDependencies,
    _ mutation: (inout AppConfiguration) -> Void
) -> CommandResultStatus {
    var edited = dependencies.config
    mutation(&edited)
    let target = SettingsCommandTarget(expectedSettingsRevision: dependencies.config.revision)
    return SettingsCommands.dispatch(edited, target: target, dependencies: dependencies)
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
