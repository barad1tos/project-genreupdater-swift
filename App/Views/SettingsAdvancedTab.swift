// SettingsAdvancedTab.swift — cleanup lists, verification controls, and JSON configuration.

import AppKit
import Core
import Services
import SharedUI
import SwiftUI

// MARK: - Advanced Tab

struct AdvancedTab: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var newEditionMarker = ""
    @State private var newAlbumSuffix = ""
    @State private var newMappingSource = ""
    @State private var newMappingTarget = ""
    @State private var newArtistRenameSource = ""
    @State private var newArtistRenameTarget = ""
    @State private var newExceptionArtist = ""
    @State private var newExceptionAlbum = ""
    @State private var ruleRemovalFlow = MetadataRuleRemovalFlow()
    @State private var showResetConfirmation = false
    @State private var configurationJSON = ""
    @State private var jsonEditorState: JSONEditorState = .idle
    @State private var jsonStatusMessage = "Loaded from current configuration"
    /// The settings revision the editor text was generated from — the CAS
    /// anchor for Apply, so stale text conflicts instead of silently
    /// overwriting changes made elsewhere since the last reload.
    @State private var editorRevision: UInt64 = 0

    var body: some View {
        Form {
            genreMappingsSection
            artistRenamerSection
            editionMarkersSection
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
        .confirmRuleRemoval($ruleRemovalFlow, apply: removeRules)
    }

    private var genreMappingsSection: some View {
        MappingsEditor(
            title: "Genre Mappings",
            emptyMessage: "No genre mappings configured",
            footerText: "After genre determination, matching From values are replaced with To values.",
            mappings: Binding(
                get: { dependencies.config.cleaning.genreMappings },
                set: { newValue in
                    applyMutation { $0.cleaning.genreMappings = newValue }
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
                    applyMutation { $0.artistRenamer.mappings = newValue }
                }
            ),
            newSource: $newArtistRenameSource,
            newTarget: $newArtistRenameTarget
        )
    }

    private var editionMarkersSection: some View {
        let snapshot = dependencies.config.cleaning.editionMarkers

        return Section("Edition Text Markers") {
            ForEach(Array(snapshot.enumerated()), id: \.offset) { _, keyword in
                Text(keyword)
            }
            .onDelete { offsets in
                requestRemoval(
                    from: snapshot,
                    at: offsets,
                    group: .editionMarkers
                )
            }

            HStack {
                TextField("New marker", text: $newEditionMarker)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addEditionMarker() }
                    .disabled(newEditionMarker.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var albumSuffixesSection: some View {
        let snapshot = dependencies.config.cleaning.albumSuffixes

        return Section("Album Suffixes to Remove") {
            ForEach(Array(snapshot.enumerated()), id: \.offset) { _, suffix in
                Text(suffix)
            }
            .onDelete { offsets in
                requestRemoval(
                    from: snapshot,
                    at: offsets,
                    group: .albumSuffixes
                )
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
                    applyMutation { $0.yearRetrieval.scoring.yearDiffPenaltyScale = -Int(newValue) }
                }
            )
            let maxPenaltyBinding = Binding<Double>(
                get: { Double(abs(dependencies.config.yearRetrieval.scoring.yearDiffMaxPenalty)) },
                set: { newValue in
                    applyMutation { $0.yearRetrieval.scoring.yearDiffMaxPenalty = -Int(newValue) }
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
            Text(
                "Removing metadata rules here can change cleaning, matching, or lookup behavior. "
                    + "The list editors above warn before removing built-in rules."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextEditor(text: $configurationJSON)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)

            HStack {
                Button { reloadJSON() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }

                Button { formatJSON() } label: {
                    // noinspection SpellCheckingInspection — canonical SF Symbol identifier
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
                Button("Cancel", role: .cancel) {
                    // Dismissal is the whole action.
                }
            }
        }
    }

    private func addEditionMarker() {
        let trimmed = newEditionMarker.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if applyMutation({ $0.cleaning.editionMarkers.append(trimmed) }) == .accepted {
            newEditionMarker = ""
        }
    }

    private func addAlbumSuffix() {
        let trimmed = newAlbumSuffix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if applyMutation({ $0.cleaning.albumSuffixes.append(trimmed) }) == .accepted {
            newAlbumSuffix = ""
        }
    }

    private func requestRemoval(
        from values: [String],
        at offsets: IndexSet,
        group: MetadataRuleGroup
    ) {
        guard let removal = MetadataRuleRemoval(group: group, snapshot: values, offsets: offsets) else { return }
        ruleRemovalFlow.request(removal, apply: removeRules)
    }

    private func removeRules(_ removal: MetadataRuleRemoval) -> RuleRemovalOutcome {
        guard let updated = removal.removing(from: dependencies.config) else { return .stale }
        return RuleRemovalOutcome(status: applyMutation { $0 = updated })
    }

    /// Dispatches a settings command and refreshes the JSON preview to the
    /// resulting truth (accepted or rolled back).
    @discardableResult
    private func applyMutation(_ mutation: (inout AppConfiguration) -> Void) -> CommandResultStatus {
        let status = mutateConfiguration(dependencies, mutation)
        reloadJSON()
        return status
    }

    private func resetConfiguration() {
        // Deliberate live-revision target: reset is a user-confirmed
        // destructive clobber of whatever the current settings are.
        SettingsCommands.dispatch(
            AppConfiguration(),
            target: SettingsCommandTarget(expectedSettingsRevision: dependencies.config.revision),
            dependencies: dependencies
        )
        reloadJSON()
    }

    private func reloadJSON() {
        do {
            configurationJSON = try Self.encodeConfiguration(dependencies.config)
            editorRevision = dependencies.config.revision
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
            Task {
                let result = await SettingsCommands.apply(
                    decoded,
                    target: SettingsCommandTarget(expectedSettingsRevision: editorRevision),
                    dependencies: dependencies
                )
                if result.status == .accepted {
                    reloadJSON()
                    jsonEditorState = .saved
                    jsonStatusMessage = "Saved"
                } else {
                    jsonEditorState = .invalid
                    jsonStatusMessage = result.message
                }
            }
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
                applyMutation { $0.cleaning.trackCleaningExceptions.remove(atOffsets: offsets) }
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

        let status = applyMutation {
            $0.cleaning.trackCleaningExceptions.append(TrackCleaningException(artist: artist, album: album))
        }
        if status == .accepted {
            newExceptionArtist = ""
            newExceptionAlbum = ""
        }
    }
}

private enum JSONEncodingError: LocalizedError {
    case nonUTF8

    var errorDescription: String? {
        "Encoded configuration is not UTF-8."
    }
}
