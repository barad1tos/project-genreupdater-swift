// SettingsSupport.swift — shared settings bindings and display helpers.

import Core
import DesignUI
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

/// Applies an immediate UI settings mutation against the live revision.
/// Synchronous command acceptance keeps controlled fields in the same render turn.
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

/// Saves a staged artist scope against the revision captured when the picker opened.
/// Stale and failed results leave the persisted scope unchanged.
@MainActor
func saveArtistScope(
    _ change: ArtistScopeChange,
    dependencies: AppDependencies
) -> ArtistScopeSaveResult {
    var configuration = dependencies.config
    configuration.development.testArtists = ArtistAllowList.normalized(change.selected)
    let target = SettingsCommandTarget(expectedSettingsRevision: change.expectedSettingsRevision)

    switch SettingsCommands.dispatch(configuration, target: target, dependencies: dependencies) {
    case .accepted:
        return .accepted
    case .rejectedStale:
        return .stale
    case .alreadyCovered,
         .blockedByPermission,
         .blockedByRecovery,
         .navigated,
         .noOp,
         .queued,
         .rejectedInvalid,
         .requiresAttention,
         .temporaryUnavailable:
        return .failed
    }
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
