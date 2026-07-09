// SettingsAdvancedTab.swift — cleanup lists, verification controls, and JSON configuration.

import AppKit
import Core
import SharedUI
import SwiftUI

// MARK: - Advanced Tab

struct AdvancedTab: View {
    @Environment(AppDependencies.self) private var dependencies
    // swiftlint:disable:next inclusive_language
    @State private var newRemasterKeyword = ""
    @State private var newAlbumSuffix = ""
    @State private var newMappingSource = ""
    @State private var newMappingTarget = ""
    @State private var newArtistRenameSource = ""
    @State private var newArtistRenameTarget = ""
    @State private var newExceptionArtist = ""
    @State private var newExceptionAlbum = ""
    @State private var showResetConfirmation = false
    @State private var configurationJSON = ""
    @State private var jsonEditorState: JSONEditorState = .idle
    @State private var jsonStatusMessage = "Loaded from current configuration"

    var body: some View {
        Form {
            genreMappingsSection
            artistRenamerSection
            editionKeywordsSection
            albumSuffixesSection
            AlbumTypeDetectionSection(dependencies: dependencies)
            SettingsTestArtistsSection(dependencies: dependencies)
            cleaningExceptionsSection
            debugSection
            yearPenaltySection
            CountryScoringSection(dependencies: dependencies)
            ScoringWeightsSection(dependencies: dependencies)
            VerificationSettingsSection(dependencies: dependencies)
            advancedJSONSection
            resetSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if configurationJSON.isEmpty {
                reloadJSON()
            }
        }
    }

    private var genreMappingsSection: some View {
        MappingsEditor(
            title: "Genre Mappings",
            emptyMessage: "No genre mappings configured",
            footerText: "After genre determination, matching From values are replaced with To values.",
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

    private var artistRenamerSection: some View {
        MappingsEditor(
            title: "Artist Renames",
            emptyMessage: "No artist rename mappings configured",
            footerText: "Matching track artists are renamed before metadata changes are previewed or applied.",
            mappings: Binding(
                get: { dependencies.config.artistRenamer.mappings },
                set: { newValue in
                    dependencies.config.artistRenamer.mappings = newValue
                    saveConfig()
                }
            ),
            newSource: $newArtistRenameSource,
            newTarget: $newArtistRenameTarget
        )
    }

    private var editionKeywordsSection: some View {
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
    }

    private var albumSuffixesSection: some View {
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
    }

    private var debugSection: some View {
        Section("Debug") {
            Toggle("Debug mode", isOn: configBinding(dependencies, \.development.debugMode))
            Toggle("Analytics", isOn: configBinding(dependencies, \.analytics.enabled))

            Picker("Change display", selection: configBinding(dependencies, \.reporting.changeDisplayMode)) {
                ForEach(ChangeDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    private var yearPenaltySection: some View {
        Section("Year Difference Penalty") {
            let penaltyScaleBinding = Binding<Double>(
                get: { Double(abs(dependencies.config.yearRetrieval.scoring.yearDiffPenaltyScale)) },
                set: { newValue in
                    dependencies.config.yearRetrieval.scoring.yearDiffPenaltyScale = -Int(newValue)
                    saveConfig()
                }
            )
            let maxPenaltyBinding = Binding<Double>(
                get: { Double(abs(dependencies.config.yearRetrieval.scoring.yearDiffMaxPenalty)) },
                set: { newValue in
                    dependencies.config.yearRetrieval.scoring.yearDiffMaxPenalty = -Int(newValue)
                    saveConfig()
                }
            )

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading) {
                    Text(
                        "Penalty per year difference: \(abs(dependencies.config.yearRetrieval.scoring.yearDiffPenaltyScale))"
                    )
                    Slider(value: penaltyScaleBinding, in: 0 ... 20, step: 1)
                }

                VStack(alignment: .leading) {
                    Text(
                        "Maximum penalty cap: \(abs(dependencies.config.yearRetrieval.scoring.yearDiffMaxPenalty))"
                    )
                    Slider(value: maxPenaltyBinding, in: 0 ... 100, step: 5)
                }
            }
        }
    }

    private var advancedJSONSection: some View {
        Section("Advanced JSON") {
            TextEditor(text: $configurationJSON)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)

            HStack {
                Button { reloadJSON() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Button { formatJSON() } label: {
                    Label("Format", systemImage: "text.alignleft")
                }

                Button { copyJSON() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Spacer()

                Button { applyJSON() } label: {
                    Label("Apply", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(Ayu.accent)
            }

            HStack(spacing: 6) {
                Image(systemName: jsonEditorState.symbolName)
                    .foregroundStyle(jsonEditorState.color)
                Text(jsonStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resetSection: some View {
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
        saveConfiguration(dependencies)
        reloadJSON()
    }

    private func resetConfiguration() {
        dependencies.config = AppConfiguration()
        saveConfig()
    }

    private func reloadJSON() {
        do {
            configurationJSON = try Self.encodeConfiguration(dependencies.config)
            jsonEditorState = .valid
            jsonStatusMessage = "Loaded from current configuration"
        } catch {
            jsonEditorState = .invalid
            jsonStatusMessage = "Encode failed: \(error.localizedDescription)"
        }
    }

    private func formatJSON() {
        do {
            let decoded = try Self.decodeConfiguration(configurationJSON)
            configurationJSON = try Self.encodeConfiguration(decoded)
            jsonEditorState = .valid
            jsonStatusMessage = "JSON is valid"
        } catch {
            jsonEditorState = .invalid
            jsonStatusMessage = "Invalid JSON: \(error.localizedDescription)"
        }
    }

    private func copyJSON() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configurationJSON, forType: .string)
        jsonEditorState = .copied
        jsonStatusMessage = "Copied"
    }

    private func applyJSON() {
        do {
            let decoded = try Self.decodeConfiguration(configurationJSON)
            dependencies.config = decoded
            try dependencies.config.save()
            dependencies.applyRuntimeConfiguration()
            configurationJSON = try Self.encodeConfiguration(decoded)
            jsonEditorState = .saved
            jsonStatusMessage = "Saved"
        } catch {
            jsonEditorState = .invalid
            jsonStatusMessage = "Apply failed: \(error.localizedDescription)"
        }
    }

    static func decodeConfiguration(_ jsonString: String) throws -> AppConfiguration {
        try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: Data(jsonString.utf8))
    }

    private static func encodeConfiguration(_ config: AppConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        guard let jsonString = String(bytes: data, encoding: .utf8) else {
            throw JSONEncodingError.nonUTF8
        }
        return jsonString
    }
}

extension AdvancedTab {
    private var cleaningExceptionsSection: some View {
        Section("Cleaning Exceptions") {
            ForEach(
                Array(dependencies.config.cleaning.trackCleaningExceptions.enumerated()),
                id: \.offset
            ) { _, exception in
                VStack(alignment: .leading, spacing: 2) {
                    Text(exception.artist)
                    Text(exception.album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                dependencies.config.cleaning.trackCleaningExceptions.remove(atOffsets: offsets)
                saveConfig()
            }

            HStack {
                TextField("Artist", text: $newExceptionArtist)
                    .textFieldStyle(.roundedBorder)
                TextField("Album", text: $newExceptionAlbum)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addCleaningException() }
                    .disabled(!canAddCleaningException)
            }
        }
    }

    private var canAddCleaningException: Bool {
        !trimmedExceptionArtist.isEmpty && !trimmedExceptionAlbum.isEmpty
    }

    private var trimmedExceptionArtist: String {
        newExceptionArtist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedExceptionAlbum: String {
        newExceptionAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addCleaningException() {
        let artist = trimmedExceptionArtist
        let album = trimmedExceptionAlbum
        guard !artist.isEmpty, !album.isEmpty else { return }

        let alreadyExists = dependencies.config.cleaning.trackCleaningExceptions.contains { exception in
            exception.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(artist) == .orderedSame
                && exception.album.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(album) == .orderedSame
        }
        guard !alreadyExists else {
            newExceptionArtist = ""
            newExceptionAlbum = ""
            return
        }

        dependencies.config.cleaning.trackCleaningExceptions.append(TrackCleaningException(
            artist: artist,
            album: album
        ))
        newExceptionArtist = ""
        newExceptionAlbum = ""
        saveConfig()
    }
}

private enum JSONEncodingError: LocalizedError {
    case nonUTF8

    var errorDescription: String? {
        "Encoded configuration is not UTF-8."
    }
}
