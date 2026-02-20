// OnboardingView.swift — First-launch script installation wizard
// NEW: No Python equivalent (Python runs outside sandbox, no installation needed)
//
// macOS sandbox requires AppleScript files in ~/Library/Application Scripts/<bundle-id>/.
// This view guides the user through:
// 1. Explaining why scripts are needed
// 2. Installing them from the app bundle
// 3. Requesting Music.app access
//
// The wizard runs only once — after scripts are installed, the app skips to MainView.

import Core
import Services
import SwiftUI

// MARK: - Onboarding View

struct OnboardingView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var currentStep: OnboardingStep = .welcome
    @State private var installationProgress: InstallationProgress = .idle
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            StepIndicator(currentStep: currentStep)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            // Step content
            Group {
                switch currentStep {
                case .welcome:
                    WelcomeStep(onContinue: { currentStep = .installScripts })

                case .installScripts:
                    InstallScriptsStep(
                        progress: installationProgress,
                        errorMessage: errorMessage,
                        onInstall: installScripts
                    )

                case .musicAccess:
                    MusicAccessStep(onContinue: requestMusicAccess)

                case .complete:
                    CompleteStep(onFinish: {
                        Task { await dependencies.onboardingComplete() }
                    })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
        .frame(width: 600, height: 450)
    }

    // MARK: - Actions

    private func installScripts() {
        Task {
            installationProgress = .installing
            errorMessage = nil

            guard let installer = dependencies.scriptInstaller else {
                installationProgress = .failed
                errorMessage = "Script installer not available."
                return
            }

            do {
                let installed = try await installer.installScripts()
                if installed.isEmpty {
                    installationProgress = .failed
                    errorMessage = "No scripts were installed."
                } else {
                    installationProgress = .success(count: installed.count)
                    // Auto-advance after brief delay
                    try? await Task.sleep(for: .seconds(1))
                    currentStep = .musicAccess
                }
            } catch {
                installationProgress = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestMusicAccess() {
        Task {
            let reader = MusicLibraryReader()
            do {
                try await reader.requestAuthorization()
                currentStep = .complete
            } catch {
                // User denied — still allow continuing (they can grant later)
                currentStep = .complete
            }
        }
    }
}

// MARK: - Onboarding Steps

private enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case installScripts = 1
    case musicAccess = 2
    case complete = 3

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .installScripts: "Install Scripts"
        case .musicAccess: "Music Access"
        case .complete: "Ready"
        }
    }
}

private enum InstallationProgress {
    case idle
    case installing
    case success(count: Int)
    case failed
}

// MARK: - Step Indicator

private struct StepIndicator: View {
    let currentStep: OnboardingStep

    var body: some View {
        HStack(spacing: 24) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)

                    if step.rawValue < OnboardingStep.allCases.count - 1 {
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(step.rawValue <= currentStep.rawValue ? .primary : .secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Welcome Step

private struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Welcome to Genre Updater")
                .font(.title)
                .fontWeight(.bold)

            Text(
                "Automatically update genres and release years "
                    + "for your Music library using MusicBrainz, "
                    + "Discogs, and Apple Music data."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)

            Spacer()

            Button("Get Started") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Install Scripts Step

private struct InstallScriptsStep: View {
    let progress: InstallationProgress
    let errorMessage: String?
    let onInstall: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "applescript.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Install AppleScript Components")
                .font(.title2)
                .fontWeight(.semibold)

            Text(
                "Genre Updater needs AppleScript files to write "
                    + "metadata to Music.app. These scripts are bundled "
                    + "with the app and will be installed to a secure "
                    + "system directory."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            Spacer()

            switch progress {
            case .idle:
                Button("Install Scripts", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

            case .installing:
                ProgressView("Installing scripts...")

            case let .success(count):
                Label("\(count) scripts installed successfully", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .failed:
                VStack(spacing: 8) {
                    Label("Installation failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Retry", action: onInstall)
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - Music Access Step

private struct MusicAccessStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Music Library Access")
                .font(.title2)
                .fontWeight(.semibold)

            Text(
                "Genre Updater uses Apple's MusicKit to read your "
                    + "library. You'll be asked to grant access — this "
                    + "is required to view and update your tracks."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)

            Spacer()

            Button("Grant Access") {
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

// MARK: - Complete Step

private struct CompleteStep: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("All Set!")
                .font(.title)
                .fontWeight(.bold)

            Text("Genre Updater is ready to use. Your library will be loaded automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()

            Button("Start Using Genre Updater") {
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
