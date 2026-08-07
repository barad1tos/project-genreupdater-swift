// StatusBarExtra.swift — the menu bar status item, a Chrome projection consumer.

import Services
import SwiftUI

/// Maps chrome severity onto the status item's symbol; a pure helper so
/// the mapping is pinnable.
enum StatusBarSymbol {
    static func name(for severity: ChromeStatusSeverity) -> String {
        switch severity {
        case .nominal: "music.note"
        case .attention: "exclamationmark.triangle"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }
}

/// The status item's menu content (ADR 0006: recovery must be visible
/// without an open window; ADR 0012: everything rendered here is the
/// shared chrome truth, never derived locally).
struct StatusBarMenu: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let chrome = dependencies.chrome

        Text(chrome.syncStatus.text)
        Text("Mode: \(chrome.safety.processingModeLabel)")
        if chrome.safety.recoveryHold != nil {
            Text("Recovery needed — writes held")
        }
        if let scope = chrome.library.effectiveScope, scope.isNarrowedFromPhysical {
            Text("Scope: \(scope.sourceLabel)")
        }

        Divider()

        if let runCommand = chrome.commands.first(where: { $0.commandKind == .runManually }) {
            Button(runCommand.title) {
                Task { await dependencies.performChromeCommand(.runManually) }
            }
            .disabled(!runCommand.isEnabled)
        }
        if let resumeCommand = chrome.commands.first(where: { $0.commandKind == .resumeRecovery }) {
            Button(resumeCommand.title) {
                Task { await dependencies.performChromeCommand(.resumeRecovery) }
            }
            .disabled(!resumeCommand.isEnabled)
        }

        Divider()

        Button("Open Genre Updater") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
