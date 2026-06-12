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
    @State private var newExceptionArtist = ""
    @State private var newExceptionAlbum = ""
    @State private var showResetConfirmation = false
    @State private var configurationJSON = ""
    @State private var jsonEditorState: JSONEditorState = .idle
    @State private var jsonStatusMessage = "Loaded from current configuration"

    var body: some View {
        Form {
            genreMappingsSection
            editionKeywordsSection
            albumSuffixesSection
            AlbumTypeDetectionSection(dependencies: dependencies)
            cleaningExceptionsSection
            debugSection
            yearPenaltySection
            verificationSection
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

    private var verificationSection: some View {
        Section("Verification") {
            Stepper(value: configBinding(dependencies, \.databaseVerification.autoVerifyDays), in: 1 ... 90) {
                LabeledContent(
                    "Database verify interval",
                    value: "\(dependencies.config.databaseVerification.autoVerifyDays)d"
                )
            }

            Stepper(value: configBinding(dependencies, \.databaseVerification.batchSize), in: 1 ... 100) {
                LabeledContent(
                    "Verification batch size",
                    value: "\(dependencies.config.databaseVerification.batchSize)"
                )
            }

            Stepper(value: configBinding(dependencies, \.pendingVerification.autoVerifyDays), in: 1 ... 90) {
                LabeledContent(
                    "Pending verify interval",
                    value: "\(dependencies.config.pendingVerification.autoVerifyDays)d"
                )
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

    private static func decodeConfiguration(_ jsonString: String) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(jsonString.utf8))
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

// MARK: - Album Type Detection Section

private struct AlbumTypeDetectionSection: View {
    let dependencies: AppDependencies

    @State private var newSpecialPattern = ""
    @State private var newCompilationPattern = ""
    @State private var newReissuePattern = ""
    @State private var newSoundtrackPattern = ""
    @State private var newVariousArtistName = ""

    var body: some View {
        patternSection(
            "Special album patterns",
            keyPath: \.specialPatterns,
            newValue: $newSpecialPattern,
            placeholder: "archive"
        )
        patternSection(
            "Compilation patterns",
            keyPath: \.compilationPatterns,
            newValue: $newCompilationPattern,
            placeholder: "greatest hits"
        )
        patternSection(
            "Reissue patterns",
            keyPath: \.reissuePatterns,
            newValue: $newReissuePattern,
            placeholder: "anniversary"
        )
        patternSection(
            "Soundtrack patterns",
            keyPath: \.soundtrackPatterns,
            newValue: $newSoundtrackPattern,
            placeholder: "original score"
        )
        patternSection(
            "Various artists names",
            keyPath: \.variousArtistsNames,
            newValue: $newVariousArtistName,
            placeholder: "Various Artists"
        )
    }

    private func patternSection(
        _ title: String,
        keyPath: WritableKeyPath<AlbumTypeDetectionConfig, [String]>,
        newValue: Binding<String>,
        placeholder: String
    ) -> some View {
        Section(title) {
            ForEach(values(for: keyPath), id: \.self) { value in
                Text(value)
            }
            .onDelete { offsets in
                dependencies.config.albumTypeDetection[keyPath: keyPath].remove(atOffsets: offsets)
                saveConfig()
            }

            HStack {
                TextField(placeholder, text: newValue)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    addPattern(newValue, to: keyPath)
                }
                .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func values(for keyPath: WritableKeyPath<AlbumTypeDetectionConfig, [String]>) -> [String] {
        dependencies.config.albumTypeDetection[keyPath: keyPath]
    }

    private func addPattern(
        _ newValue: Binding<String>,
        to keyPath: WritableKeyPath<AlbumTypeDetectionConfig, [String]>
    ) {
        let trimmed = newValue.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dependencies.config.albumTypeDetection[keyPath: keyPath].append(trimmed)
        newValue.wrappedValue = ""
        saveConfig()
    }

    private func saveConfig() {
        saveConfiguration(dependencies)
    }
}

private enum JSONEncodingError: LocalizedError {
    case nonUTF8

    var errorDescription: String? {
        "Encoded configuration is not UTF-8."
    }
}
