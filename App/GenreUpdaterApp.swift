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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
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
                Button("Refresh Library") {
                    Task { await dependencies.refreshLibrary() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Update") {
                Button("Update Selected Tracks") {
                    NotificationCenter.default.post(
                        name: .updateSelectedTracks,
                        object: nil
                    )
                }
                .keyboardShortcut("u", modifiers: .command)
            }

            NavigationCommands()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive {
                Task { await dependencies.saveState() }
            }
        }

        Settings {
            SettingsView()
                .environment(dependencies)
                .environment(\.motionScale, fastAnimations ? 0.5 : 1.0)
                .preferredColorScheme(appearanceMode.colorScheme)
                .animation(Motion.curveDefault, value: appearanceMode)
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
    /// Posted by the Update menu command (Cmd+U) to navigate to the Update screen.
    static let updateSelectedTracks = Notification.Name("GenreUpdater.updateSelectedTracks")

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
