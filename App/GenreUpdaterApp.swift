// GenreUpdaterApp.swift — SwiftUI app entry point
// NEW: No Python equivalent (Python used CLI argparse)
//
// This replaces the entire CLI layer (cli.py + main.py) with SwiftUI's
// declarative app lifecycle. WindowGroup handles window creation,
// @Observable + @Environment propagates dependencies, and ScenePhase provides lifecycle hooks.

import AppKit
import Core
import Services
import SharedUI
import SwiftData
import SwiftUI

@main
struct GenreUpdaterApp: App {
    @State private var dependencies = AppDependencies()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("fastAnimations") private var fastAnimations = false

    var body: some Scene {
        // Single-instance window: openWindow(id:) from the status item
        // brings this one forward instead of creating a second shell.
        Window("Genre Updater", id: "main") {
            ContentView()
                .environment(dependencies)
                .environment(\.motionScale, fastAnimations ? 0.5 : 1.0)
                .optionalModelContainer(dependencies.modelContainer)
                .preferredColorScheme(appearanceMode.colorScheme)
                .animation(Motion.curveDefault, value: appearanceMode)
                .onChange(of: appearanceMode) { _, newMode in
                    applyAppKitAppearance(newMode)
                }
                .task {
                    await dependencies.initialize()
                    applyAppKitAppearance(appearanceMode)
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Replace default "New Window" with custom commands
            }

            CommandMenu("Library") {
                // The menu renders the chrome projection's descriptors —
                // title, availability, and hold degradation come from the
                // shared shell truth, never a local guess (ADR 0012).
                let runCommand = dependencies.chrome.commands.first { $0.commandKind == .runManually }
                Button(runCommand?.title ?? "Run now") {
                    Task { await dependencies.performChromeCommand(.runManually) }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(runCommand?.isEnabled != true)

                if let resumeCommand = dependencies.chrome.commands
                    .first(where: { $0.commandKind == .resumeRecovery }) {
                    Button(resumeCommand.title) {
                        Task { await dependencies.performChromeCommand(.resumeRecovery) }
                    }
                    .disabled(!resumeCommand.isEnabled)
                }
            }

            NavigationCommands()
        }
        Settings {
            SettingsView()
                .environment(dependencies)
                .environment(\.motionScale, fastAnimations ? 0.5 : 1.0)
                .preferredColorScheme(appearanceMode.colorScheme)
                .animation(Motion.curveDefault, value: appearanceMode)
        }

        // ADR 0006: recovery must be visible without an open window; the
        // status item renders the same chrome truth as every shell zone.
        MenuBarExtra {
            StatusBarMenu()
                .environment(dependencies)
        } label: {
            // The severity read lives in a view BODY so observation
            // tracking re-renders the icon; an argument expression in
            // App.body has no verified tracking site.
            StatusBarLabel(dependencies: dependencies)
        }
    }

    /// Syncs AppKit's global appearance to match the SwiftUI color scheme.
    ///
    /// Setting `NSApp.appearance` to `nil` for `.system` lets AppKit surfaces
    /// (sheets, date pickers, context menus) track the OS setting in real time.
    private func applyAppKitAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Content View (Router)

/// Root content view that decides between onboarding and main interface.
struct ContentView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        Group {
            switch dependencies.appState {
            case .loading:
                ProgressView("Initializing...")
                    .frame(width: 300, height: 200)

            case .needsOnboarding:
                OnboardingView()

            case .ready:
                DesignRootHostView()

            case let .error(message):
                ErrorView(message: message) {
                    Task { await dependencies.initialize() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.curveDefault, value: "\(dependencies.appState)")
    }
}

// MARK: - Error View

struct ErrorView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Ayu.warning)
                .accessibilityHidden(true)

            Text("Something went wrong")
                .font(AppFont.headline)
                .foregroundStyle(Ayu.fgPrimary)

            Text(message)
                .font(AppFont.body)
                .foregroundStyle(Ayu.fgSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxxl)

            Button("Try Again", action: retryAction)
                .buttonStyle(.borderedProminent)
                .tint(Ayu.accent)
                .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by Reports empty state to navigate to the Update screen.
    static let navigateToUpdate = Notification.Name("GenreUpdater.navigateToUpdate")
}

// MARK: - Navigation Commands

/// Cmd+1 through Cmd+9 shortcuts for sidebar categories.
struct NavigationCommands: Commands {
    @FocusedValue(\.selectedCategory) private var selectedCategory

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(
                Array(NavigationCategory.allInOrder.enumerated()),
                id: \.element.id
            ) { index, category in
                Button(category.rawValue) {
                    selectedCategory?.wrappedValue = category
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: .command
                )
            }
        }
    }
}

// MARK: - Optional Model Container

extension View {
    /// Attaches a `ModelContainer` to the view hierarchy when available.
    ///
    /// If the container is nil (ModelContainerFactory failed in init), the view
    /// renders without SwiftData — `@Query` properties will return empty results
    /// until the container is created during `initialize()`.
    @ViewBuilder
    fileprivate func optionalModelContainer(_ container: ModelContainer?) -> some View {
        if let container {
            self.modelContainer(container)
        } else {
            self
        }
    }
}
