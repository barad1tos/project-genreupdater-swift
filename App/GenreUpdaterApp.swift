// GenreUpdaterApp.swift — SwiftUI app entry point
// NEW: No Python equivalent (Python used CLI argparse)
//
// This replaces the entire CLI layer (cli.py + main.py) with SwiftUI's
// declarative app lifecycle. WindowGroup handles window creation,
// @Environment propagates dependencies, and ScenePhase provides lifecycle hooks.

import Core
import Services
import SwiftUI

@main
struct GenreUpdaterApp: App {
    @StateObject private var dependencies = AppDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dependencies)
                .task {
                    await dependencies.initialize()
                }
        }
        .commands {
            // Replace default "New Window" with custom commands
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Library") {
                Button("Refresh Library") {
                    Task { await dependencies.refreshLibrary() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive {
                Task { await dependencies.saveState() }
            }
        }

        Settings {
            SettingsPlaceholderView()
                .environmentObject(dependencies)
        }
    }
}

// MARK: - Content View (Router)

/// Root content view that decides between onboarding and main interface.
struct ContentView: View {
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        Group {
            switch dependencies.appState {
            case .loading:
                ProgressView("Initializing...")
                    .frame(width: 300, height: 200)

            case .needsOnboarding:
                OnboardingView()

            case .ready:
                MainView()

            case .error(let message):
                ErrorView(message: message) {
                    Task { await dependencies.initialize() }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Error View

struct ErrorView: View {
    let message: String
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("Something went wrong")
                .font(.title2)
                .fontWeight(.semibold)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Try Again", action: retryAction)
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Settings Placeholder

struct SettingsPlaceholderView: View {
    var body: some View {
        Text("Settings will be implemented in Phase 6")
            .frame(width: 400, height: 300)
            .padding()
    }
}
