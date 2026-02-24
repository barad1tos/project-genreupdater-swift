// SettingsView.swift — Settings with 4 tabs: General, API & Cache, Advanced, Appearance.

import Core
import Services
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

// MARK: - Settings View

struct SettingsView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }

            APIAndCacheTab()
                .tabItem { Label("API & Cache", systemImage: "key") }

            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench") }

            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 520)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @Environment(AppDependencies.self) private var dependencies
    @AppStorage("defaultUpdateBehavior") private var updateBehavior: String = UpdateBehavior.both.rawValue
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        Form {
            Section("Update Behavior") {
                Picker("Default update behavior", selection: $updateBehavior) {
                    ForEach(UpdateBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Show notifications on completion", isOn: $showNotifications)
            }

            Section("Confidence Thresholds") {
                let confidenceBinding = Binding<Double>(
                    get: { Double(dependencies.config.yearRetrieval.logic.minConfidenceForNewYear) },
                    set: { newValue in
                        dependencies.config.yearRetrieval.logic.minConfidenceForNewYear = newValue
                        saveConfig()
                    }
                )

                VStack(alignment: .leading) {
                    Text("Minimum confidence: \(Int(dependencies.config.yearRetrieval.logic.minConfidenceForNewYear))%")
                    Slider(value: confidenceBinding, in: 0 ... 100, step: 5)
                }

                let definitiveBinding = Binding<Double>(
                    get: { Double(dependencies.config.yearRetrieval.logic.definitiveScoreThreshold) },
                    set: { newValue in
                        dependencies.config.yearRetrieval.logic.definitiveScoreThreshold = Int(newValue)
                        saveConfig()
                    }
                )

                VStack(alignment: .leading) {
                    Text(
                        "Definitive score threshold: \(dependencies.config.yearRetrieval.logic.definitiveScoreThreshold)"
                    )
                    Slider(value: definitiveBinding, in: 0 ... 100, step: 5)
                }
            }

            Section("Subscription") {
                if let gate = dependencies.featureGate {
                    HStack {
                        Text("Current plan")
                        Spacer()
                        TierBadge(tier: gate.currentTier)
                    }
                }
                NavigationLink("Manage Subscription") {
                    SubscriptionView()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveConfig() {
        try? dependencies.config.save()
    }
}

// MARK: - API & Cache Tab

private struct APIAndCacheTab: View {
    private static let discogsService = "GenreUpdater-Discogs"
    private static let discogsAccount = "pat"

    private enum TokenStatus {
        case unknown, saved, missing, error
        var symbolName: String {
            switch self {
            case .unknown: "questionmark.circle"
            case .saved: "checkmark.circle.fill"
            case .missing: "xmark.circle"
            case .error: "exclamationmark.triangle.fill"
            }
        }
        var color: Color {
            switch self {
            case .unknown: .secondary
            case .saved: Ayu.success
            case .missing: Ayu.warning
            case .error: Ayu.error
            }
        }
    }

    @Environment(AppDependencies.self) private var dependencies
    @AppStorage("contactEmail") private var contactEmail = ""
    @State private var tokenInput = ""
    @State private var tokenStatus: TokenStatus = .unknown
    @State private var statusMessage = ""
    @State private var cacheStatistics: CacheStatistics?
    @State private var isLoadingStatistics = false
    @State private var isClearingCache = false

    private let keychain = KeychainHelper()

    var body: some View {
        Form {
            Section {
                TextField("Contact Email", text: $contactEmail)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Contact Information")
            } footer: {
                Text("Required by MusicBrainz, recommended by Discogs.")
            }

            Section {
                SecureField("Discogs Personal Access Token", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: Spacing.sm) {
                    Button("Save Token") { saveToken() }
                        .disabled(tokenInput.isEmpty)
                    Button("Delete Token", role: .destructive) { deleteToken() }
                    Button("Test Token") { testToken() }
                }
                HStack(spacing: 6) {
                    Image(systemName: tokenStatus.symbolName)
                        .foregroundStyle(tokenStatus.color)
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } header: {
                Text("Discogs API")
            }

            Section("Cache Statistics") {
                if let statistics = cacheStatistics {
                    LabeledContent("Album year entries", value: "\(statistics.albumYearCount)")
                    LabeledContent("API result entries", value: "\(statistics.apiResultCount)")
                    LabeledContent("Generic cache entries", value: "\(statistics.genericCacheCount)")
                    LabeledContent("Expired entries", value: "\(statistics.expiredCount)")
                } else if isLoadingStatistics {
                    ProgressView("Loading statistics...")
                } else {
                    Text("No cache data available")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh") { loadCacheStatistics() }
                        .disabled(isLoadingStatistics)
                    Button("Clear Cache", role: .destructive) { clearCache() }
                        .disabled(isClearingCache || dependencies.cacheService == nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            loadTokenStatus()
            loadCacheStatistics()
        }
    }

    private func loadTokenStatus() {
        do {
            if let existing = try keychain.retrieve(
                service: Self.discogsService,
                account: Self.discogsAccount
            ), !existing.isEmpty {
                tokenStatus = .saved
                statusMessage = "Token saved (\(existing.prefix(4))...)"
            } else {
                tokenStatus = .missing
                statusMessage = "No token configured"
            }
        } catch {
            tokenStatus = .error
            statusMessage = "Failed to read Keychain: \(error.localizedDescription)"
        }
    }

    private func saveToken() {
        do {
            try keychain.save(
                token: tokenInput,
                service: Self.discogsService,
                account: Self.discogsAccount
            )
            tokenInput = ""
            tokenStatus = .saved
            statusMessage = "Token saved successfully"
        } catch {
            tokenStatus = .error
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func deleteToken() {
        do {
            try keychain.delete(
                service: Self.discogsService,
                account: Self.discogsAccount
            )
            tokenInput = ""
            tokenStatus = .missing
            statusMessage = "Token deleted"
        } catch {
            tokenStatus = .error
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func testToken() {
        do {
            if let token = try keychain.retrieve(
                service: Self.discogsService,
                account: Self.discogsAccount
            ), !token.isEmpty {
                tokenStatus = .saved
                statusMessage = "Token is present (\(token.count) characters)"
            } else {
                tokenStatus = .missing
                statusMessage = "No token found — save one first"
            }
        } catch {
            tokenStatus = .error
            statusMessage = "Test failed: \(error.localizedDescription)"
        }
    }

    private func loadCacheStatistics() {
        isLoadingStatistics = true
        Task {
            cacheStatistics = await dependencies.cacheService?.getCacheStatistics()
            isLoadingStatistics = false
        }
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await dependencies.cacheService?.clear()
            cacheStatistics = nil
            isClearingCache = false
            loadCacheStatistics()
        }
    }
}

// MARK: - Advanced Tab

private struct AdvancedTab: View {
    @Environment(AppDependencies.self) private var dependencies
    // swiftlint:disable:next inclusive_language
    @State private var newRemasterKeyword = ""
    @State private var newAlbumSuffix = ""
    @State private var newMappingSource = ""
    @State private var newMappingTarget = ""
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Genre Mappings") {
                GenreMappingsEditor(
                    mappings: Binding(
                        get: { dependencies.config.cleaning.genreMappings },
                        set: { newValue in
                            dependencies.config.cleaning.genreMappings = newValue
                            saveConfig()
                        }
                    ),
                    newSource: $newMappingSource,
                    newTarget: $newMappingTarget
                )
            }

            Section("Remaster Keywords") {
                ForEach(dependencies.config.cleaning.remasterKeywords, id: \.self) { keyword in
                    Text(keyword)
                }
                .onDelete { offsets in
                    dependencies.config.cleaning.remasterKeywords.remove(atOffsets: offsets)
                    saveConfig()
                }

                HStack {
                    TextField("New keyword", text: $newRemasterKeyword)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addRemasterKeyword() }
                        .disabled(newRemasterKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Album Suffixes to Remove") {
                ForEach(dependencies.config.cleaning.albumSuffixesToRemove, id: \.self) { suffix in
                    Text(suffix)
                }
                .onDelete { offsets in
                    dependencies.config.cleaning.albumSuffixesToRemove.remove(atOffsets: offsets)
                    saveConfig()
                }
                HStack {
                    TextField("New suffix", text: $newAlbumSuffix)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { addAlbumSuffix() }
                        .disabled(newAlbumSuffix.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Debug") {
                let debugBinding = Binding<Bool>(
                    get: { dependencies.config.development.debugMode },
                    set: { newValue in
                        dependencies.config.development.debugMode = newValue
                        try? dependencies.config.save()
                    }
                )
                Toggle("Debug mode", isOn: debugBinding)
            }

            Section("Year Difference Penalty") {
                let penaltyScaleBinding = Binding<Double>(
                    get: { Double(abs(dependencies.config.yearRetrieval.scoring.yearDiffPenaltyScale)) },
                    set: { newValue in
                        dependencies.config.yearRetrieval.scoring.yearDiffPenaltyScale = -Int(newValue)
                        saveConfig()
                    }
                )

                VStack(alignment: .leading) {
                    Text(
                        "Penalty per year difference: \(abs(dependencies.config.yearRetrieval.scoring.yearDiffPenaltyScale))"
                    )
                    Slider(value: penaltyScaleBinding, in: 0 ... 20, step: 1)
                }
            }

            Section("Reset") {
                Button("Reset Configuration to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset all settings to defaults?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) { resetConfiguration() }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // swiftlint:disable:next inclusive_language
    private func addRemasterKeyword() {
        let trimmed = newRemasterKeyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dependencies.config.cleaning.remasterKeywords.append(trimmed)
        newRemasterKeyword = ""
        saveConfig()
    }

    private func addAlbumSuffix() {
        let trimmed = newAlbumSuffix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        dependencies.config.cleaning.albumSuffixesToRemove.append(trimmed)
        newAlbumSuffix = ""
        saveConfig()
    }

    private func saveConfig() {
        try? dependencies.config.save()
    }

    private func resetConfiguration() {
        dependencies.config = AppConfiguration()
        saveConfig()
    }
}

// MARK: - Appearance Tab

private struct AppearanceTab: View {
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("sidebarCompact") private var isSidebarCompact = false
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

            Section("Sidebar") {
                Toggle("Compact sidebar", isOn: $isSidebarCompact)

                Text(isSidebarCompact ? "Icons only" : "Icons and labels")
                    .foregroundStyle(Ayu.fgSecondary)
                    .font(AppFont.caption)
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
