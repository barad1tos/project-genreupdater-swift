import SharedUI
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(AppDependencies.self) private var dependencies
    @AppStorage(AppStorageKey.experienceLevel) private var experienceLevel: ExperienceLevel = .defaultLevel
    @AppStorage(AppStorageKey.settingsTab) private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            APICacheTab()
                .tabItem { Label("API & Cache", systemImage: "key") }
                .tag(SettingsTab.apiCache)

            // Display-only gating (ADR 0002): Casual hides the operational
            // surface; the settings behind it stay untouched and effective.
            if experienceLevel != .casual {
                AdvancedTab()
                    .tabItem { Label("Advanced", systemImage: "wrench") }
                    .tag(SettingsTab.advanced)
            }

            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
        }
        .frame(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        .scenePadding()
        .onAppear { normalizeSelectedTab() }
        .onChange(of: experienceLevel) { normalizeSelectedTab() }
    }

    private func normalizeSelectedTab() {
        if experienceLevel == .casual, selectedTab == .advanced {
            selectedTab = .general
        }
    }
}

enum SettingsTab: String {
    case general
    case apiCache
    case advanced
    case appearance
}

private enum SettingsLayout {
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 620
}

// MARK: - Appearance Tab

private struct AppearanceTab: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("fastAnimations") private var fastAnimations = false

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.symbolName)
                            .accessibilityLabel(mode.accessibilityLabel)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: Spacing.xs) {
                    ColorSwatch(color: Ayu.bgPrimary, label: "Background")
                    ColorSwatch(color: Ayu.bgSecondary, label: "Surface")
                    ColorSwatch(color: Ayu.fgPrimary, label: "Text")
                    ColorSwatch(color: Ayu.accent, label: "Accent")
                }
                .padding(.top, Spacing.xxs)
            }

            Section("Motion") {
                Toggle("Fast animations", isOn: $fastAnimations)

                Text("Halves all animation durations for snappier interaction.")
                    .foregroundStyle(Ayu.fgSecondary)
                    .font(AppFont.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Color Swatch

private struct ColorSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.xs)
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Ayu.fgMuted.opacity(0.3), lineWidth: 1))
            .accessibilityLabel(label)
    }
}
