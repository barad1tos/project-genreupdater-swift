// SettingsAPIAndCacheTab.swift — API credentials, rate limits, and cache settings.

import Core
import Services
import SharedUI
import SwiftUI

// MARK: - API & Cache Tab

struct APIAndCacheTab: View {
    private static let discogsService = "GenreUpdater-Discogs"
    private static let discogsAccount = "pat"

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
            contactSection
            yearLookupSection
            discogsSection
            cacheStatisticsSection
            cacheBehaviorSection
        }
        .formStyle(.grouped)
        .padding()
        .task {
            loadTokenStatus()
            loadCacheStatistics()
        }
    }

    private var contactSection: some View {
        Section {
            TextField("Contact Email", text: $contactEmail)
                .textFieldStyle(.roundedBorder)
        } header: {
            Text("Contact Information")
        } footer: {
            Text("Required by MusicBrainz, recommended by Discogs.")
        }
    }

    private var yearLookupSection: some View {
        Section("Year Lookup") {
            Toggle("Enable year lookup", isOn: configBinding(dependencies, \.yearRetrieval.enabled))

            Picker("Preferred API", selection: configBinding(dependencies, \.yearRetrieval.preferredAPI)) {
                ForEach(PreferredAPI.allCases, id: \.self) { api in
                    Text(api.displayName).tag(api)
                }
            }
            .pickerStyle(.segmented)

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.rateLimits.discogsRequestsPerMinute),
                in: 1 ... 120
            ) {
                LabeledContent(
                    "Discogs requests per minute",
                    value: "\(dependencies.config.yearRetrieval.rateLimits.discogsRequestsPerMinute)"
                )
            }

            Stepper(value: configBinding(dependencies, \.yearRetrieval.rateLimits.concurrentAPICalls), in: 1 ... 10) {
                LabeledContent(
                    "Concurrent API calls",
                    value: "\(dependencies.config.yearRetrieval.rateLimits.concurrentAPICalls)"
                )
            }
        }
    }

    private var discogsSection: some View {
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
    }

    private var cacheStatisticsSection: some View {
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

    private var cacheBehaviorSection: some View {
        Section("Cache Behavior") {
            Stepper(value: configBinding(dependencies, \.caching.defaultTTLSeconds), in: 60 ... 86400, step: 60) {
                LabeledContent("Default TTL", value: "\(dependencies.config.caching.defaultTTLSeconds / 60)m")
            }

            Stepper(value: configBinding(dependencies, \.runtime.cacheTTLSeconds), in: 60 ... 86400, step: 60) {
                LabeledContent("Runtime cache TTL", value: "\(dependencies.config.runtime.cacheTTLSeconds / 60)m")
            }

            Stepper(
                value: configBinding(dependencies, \.caching.negativeResultTTL),
                in: 0 ... 7_776_000,
                step: 86400
            ) {
                LabeledContent("Negative result TTL", value: negativeResultTTLDisplay)
            }

            Toggle("Library snapshot cache", isOn: configBinding(dependencies, \.caching.librarySnapshot.enabled))
            Toggle("Delta snapshots", isOn: configBinding(dependencies, \.caching.librarySnapshot.deltaEnabled))

            Stepper(value: configBinding(dependencies, \.caching.librarySnapshot.maxAgeHours), in: 1 ... 168) {
                LabeledContent("Snapshot max age", value: "\(dependencies.config.caching.librarySnapshot.maxAgeHours)h")
            }
        }
    }

    private var negativeResultTTLDisplay: String {
        let seconds = dependencies.config.caching.negativeResultTTL
        guard seconds > 0 else { return "Off" }

        let days = Int(seconds / 86400)
        if days >= 1 { return "\(days)d" }

        let hours = Int(seconds / 3600)
        return "\(max(1, hours))h"
    }

    private func loadTokenStatus() {
        do {
            if let existing = try keychain.retrieve(service: Self.discogsService, account: Self.discogsAccount),
               !existing.isEmpty {
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
            try keychain.save(token: tokenInput, service: Self.discogsService, account: Self.discogsAccount)
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
            try keychain.delete(service: Self.discogsService, account: Self.discogsAccount)
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
            if let token = try keychain.retrieve(service: Self.discogsService, account: Self.discogsAccount),
               !token.isEmpty {
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
