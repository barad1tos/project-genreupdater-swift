// SettingsView.swift — macOS Settings window (Cmd+,) with tabbed configuration.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Update Behavior

/// Controls which metadata fields the app updates by default.
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

// MARK: - Keychain Constants

private enum DiscogsKeychain {
    static let service = "GenreUpdater-Discogs"
    static let account = "pat"
}

// MARK: - Settings View

/// Tabbed settings view displayed via macOS Settings (Cmd+,).
///
/// Each tab manages a distinct configuration area: general preferences, API keys,
/// scoring parameters, cleaning rules, subscription status, and advanced/debug options.
struct SettingsView: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key") }

            ScoringTab()
                .tabItem { Label("Scoring", systemImage: "slider.horizontal.3") }

            CleaningTab()
                .tabItem { Label("Cleaning", systemImage: "scissors") }

            SubscriptionView()
                .tabItem { Label("Subscription", systemImage: "creditcard") }

            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @AppStorage("defaultUpdateBehavior") private var updateBehavior: String = UpdateBehavior.both.rawValue
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        Form {
            Picker("Default update behavior", selection: $updateBehavior) {
                ForEach(UpdateBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Show notifications on completion", isOn: $showNotifications)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - API Keys Tab

private struct APIKeysTab: View {
    @State private var tokenInput = ""
    @State private var tokenStatus: TokenStatus = .unknown
    @State private var statusMessage = ""

    private let keychain = KeychainHelper()

    var body: some View {
        Form {
            Section {
                SecureField("Discogs Personal Access Token", text: $tokenInput)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    Button("Save Token") {
                        saveToken()
                    }
                    .disabled(tokenInput.isEmpty)

                    Button("Delete Token", role: .destructive) {
                        deleteToken()
                    }

                    Button("Test Token") {
                        testToken()
                    }
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
            } footer: {
                Text(
                    "A Personal Access Token from discogs.com/settings/developers enables authenticated API requests with higher rate limits."
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            loadTokenStatus()
        }
    }

    private func loadTokenStatus() {
        do {
            if let existing = try keychain.retrieve(
                service: DiscogsKeychain.service,
                account: DiscogsKeychain.account
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
                service: DiscogsKeychain.service,
                account: DiscogsKeychain.account
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
                service: DiscogsKeychain.service,
                account: DiscogsKeychain.account
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
                service: DiscogsKeychain.service,
                account: DiscogsKeychain.account
            ), !token.isEmpty {
                tokenStatus = .saved
                statusMessage = "Token is present and non-empty (\(token.count) characters)"
            } else {
                tokenStatus = .missing
                statusMessage = "No token found — save one first"
            }
        } catch {
            tokenStatus = .error
            statusMessage = "Test failed: \(error.localizedDescription)"
        }
    }
}

private enum TokenStatus {
    case unknown
    case saved
    case missing
    case error

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
        case .saved: .green
        case .missing: .orange
        case .error: .red
        }
    }
}

// MARK: - Scoring Tab

private struct ScoringTab: View {
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveConfig() {
        try? dependencies.config.save()
    }
}

// MARK: - Cleaning Tab

private struct CleaningTab: View {
    @Environment(AppDependencies.self) private var dependencies
    // swiftlint:disable:next inclusive_language
    @State private var newRemasterKeyword = ""
    @State private var newAlbumSuffix = ""

    var body: some View {
        Form {
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
                    Button("Add") {
                        addRemasterKeyword()
                    }
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
                    Button("Add") {
                        addAlbumSuffix()
                    }
                    .disabled(newAlbumSuffix.trimmingCharacters(in: .whitespaces).isEmpty)
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
}

// MARK: - Advanced Tab

private struct AdvancedTab: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var cacheStatistics: CacheStatistics?
    @State private var isLoadingStatistics = false
    @State private var isClearingCache = false
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Cache") {
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
                    Button("Refresh Statistics") {
                        loadCacheStatistics()
                    }
                    .disabled(isLoadingStatistics)

                    Button("Clear Cache", role: .destructive) {
                        clearCache()
                    }
                    .disabled(isClearingCache || dependencies.cacheService == nil)
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

            Section("Reset") {
                Button("Reset Configuration to Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset all settings to defaults?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        resetConfiguration()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            loadCacheStatistics()
        }
    }

    private func loadCacheStatistics() {
        isLoadingStatistics = true
        Task {
            let statistics = await dependencies.cacheService?.getCacheStatistics()
            cacheStatistics = statistics
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

    private func resetConfiguration() {
        dependencies.config = AppConfiguration()
        try? dependencies.config.save()
    }
}
