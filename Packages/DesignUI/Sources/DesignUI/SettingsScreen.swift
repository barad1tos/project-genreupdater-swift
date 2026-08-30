import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: AppModel
    var setDryRunAction: ((Bool) -> Bool)?
    var setUpdateBehaviorAction: ((DesignUpdateBehavior) -> Bool)?
    var setMinimumConfidenceAction: ((Double) -> Bool)?
    var setReleaseYearRestoreThresholdAction: ((Int) -> Bool)?
    var setBulkThresholdAction: ((Int) -> Bool)?
    var setTestArtistsAction: ((ArtistScopeChange) -> ArtistScopeSaveResult)?
    var setAppearanceModeAction: ((DesignAppearanceMode) -> Bool)?
    var setFastAnimationsAction: ((Bool) -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var isReduceMotionEnabled
    @State private var tab = "general"
    @State private var stagedMinimumConfidencePercent: Double?
    @State private var isArtistPickerOpen = false
    @State private var saveStatus = SettingsSaveStatus.automatic
    @State private var isEditingMinimumConfidence = false
    @State private var minimumConfidenceCommitTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Settings").font(.system(size: 24, weight: .heavy))
                Picker("", selection: $tab) {
                    Text("General").tag("general")
                    Text("API & Cache").tag("api")
                    if settings.isAdvancedExperience {
                        Text("Advanced").tag("advanced")
                    }
                    Text("Appearance").tag("appearance")
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                Spacer()
                saveStatusView
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "api": api
                    case "appearance": appearance
                    case "advanced" where settings.isAdvancedExperience: advanced
                    default: general
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ayu.window)
        .navigationTitle("Settings")
        .onDisappear {
            commitStagedMinimumConfidence(force: true)
        }
        .onChange(of: settings.isAdvancedExperience) { _, isAdvanced in
            if !isAdvanced, tab == "advanced" {
                tab = "general"
            }
        }
        .sheet(isPresented: $isArtistPickerOpen) {
            ArtistScopePicker(scope: settings.artistScope) { change in
                let result = setTestArtistsAction?(change) ?? .failed
                recordSave(result == .accepted)
                return result
            }
        }
    }

    private var settings: DesignSettingsSnapshot {
        model.data.settings
    }

    private var displayedMinimumConfidencePercent: Double {
        stagedMinimumConfidencePercent ?? settings.minimumConfidencePercent
    }

    private var dryRunBinding: Binding<Bool> {
        Binding {
            model.dryRun
        } set: { isDryRun in
            let previousValue = model.dryRun
            model.dryRun = isDryRun
            let accepted = recordSave(setDryRunAction?(isDryRun) ?? false)
            if !accepted {
                model.dryRun = previousValue
            }
        }
    }

    private var updateBehaviorBinding: Binding<DesignUpdateBehavior> {
        Binding {
            settings.updateBehavior
        } set: { behavior in
            recordSave(setUpdateBehaviorAction?(behavior) ?? false)
        }
    }

    private var minimumConfidenceBinding: Binding<Double> {
        Binding {
            displayedMinimumConfidencePercent
        } set: { percent in
            stagedMinimumConfidencePercent = percent
            if !isEditingMinimumConfidence {
                scheduleMinimumConfidenceCommit(percent)
            }
        }
    }

    private var releaseYearRestoreThresholdBinding: Binding<Int> {
        Binding {
            settings.releaseYearRestoreThresholdYears
        } set: { years in
            recordSave(setReleaseYearRestoreThresholdAction?(years) ?? false)
        }
    }

    private var bulkThresholdBinding: Binding<Int> {
        Binding {
            settings.metadataReads.bulkThreshold
        } set: { threshold in
            recordSave(setBulkThresholdAction?(threshold) ?? false)
        }
    }

    private var appearanceModeBinding: Binding<DesignAppearanceMode> {
        Binding {
            DesignAppearanceMode.supportedModes.contains(settings.appearanceMode) ? settings.appearanceMode : .dark
        } set: { mode in
            recordSave(setAppearanceModeAction?(mode) ?? false)
        }
    }

    private var fastAnimationsBinding: Binding<Bool> {
        Binding {
            settings.isFastAnimationsEnabled
        } set: { isEnabled in
            recordSave(setFastAnimationsAction?(isEnabled) ?? false)
        }
    }

    private var general: some View {
        VStack(spacing: 14) {
            group("Update behavior", "wand.and.stars", .accent) {
                row("Fields to update", "Which metadata GenreUpdater writes during a run.") {
                    Picker("", selection: updateBehaviorBinding) {
                        ForEach(DesignUpdateBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(setUpdateBehaviorAction == nil)
                }
                row("Safe mode (dry-run)", "Always preview proposed changes before any tag is written.") {
                    Toggle("", isOn: dryRunBinding).labelsHidden().tint(Ayu.accent)
                        .disabled(setDryRunAction == nil)
                }
                row(
                    "Minimum confidence for missing years",
                    "Reject lower-confidence suggestions only when a track has no year."
                ) {
                    HStack {
                        Slider(
                            value: minimumConfidenceBinding,
                            in: 30 ... 100,
                            onEditingChanged: commitMinimumConfidenceEditing
                        )
                        .frame(width: 160)
                        .tint(Ayu.accent)
                        .disabled(setMinimumConfidenceAction == nil)
                        Text("\(Int(displayedMinimumConfidencePercent))%")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                }
            }
            group("Schedule", "clock", .info) {
                row("Automatic scan", "Current automatic scan status.") {
                    TagPill(text: model.data.chrome.automationLabel, tone: .neutral)
                }
                row("Scan cadence", "Next scheduled automatic run, when available.") {
                    TagPill(text: model.snapshot.nextRun, tone: .neutral)
                }
            }
            group("Test artists scope", "music.note.list", .purple) {
                row("Limit runs to these artists", "Leave empty to process the full library.") {
                    VStack(alignment: .trailing, spacing: 8) {
                        if settings.artistScope.selected.isEmpty {
                            TagPill(text: "Full library", tone: .neutral)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 7) {
                                    ForEach(settings.artistScope.selected, id: \.self) { artist in
                                        TagPill(text: artist, tone: .purple)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        HStack(spacing: 10) {
                            if let catalogIssue = settings.artistScope.catalogIssue {
                                Label(catalogIssue, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Ayu.warning)
                            } else {
                                Text("\(settings.artistScope.options.count) artists in your library")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Ayu.fg2)
                            }
                            BorderedButton(
                                title: "Choose artists",
                                symbol: "person.2",
                                enabled: setTestArtistsAction != nil,
                                action: openArtistPicker
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func commitMinimumConfidenceEditing(_ isEditing: Bool) {
        isEditingMinimumConfidence = isEditing
        if isEditing {
            minimumConfidenceCommitTask?.cancel()
            minimumConfidenceCommitTask = nil
            return
        }
        commitStagedMinimumConfidence()
    }

    private func scheduleMinimumConfidenceCommit(_ percent: Double) {
        minimumConfidenceCommitTask?.cancel()
        minimumConfidenceCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, stagedMinimumConfidencePercent == percent else { return }
            commitStagedMinimumConfidence()
        }
    }

    private func commitStagedMinimumConfidence(force: Bool = false) {
        guard force || !isEditingMinimumConfidence, let stagedMinimumConfidencePercent else { return }
        minimumConfidenceCommitTask?.cancel()
        minimumConfidenceCommitTask = nil
        recordSave(setMinimumConfidenceAction?(stagedMinimumConfidencePercent) ?? false)
        self.stagedMinimumConfidencePercent = nil
    }

    private var saveStatusView: some View {
        Label(saveStatus.label, systemImage: saveStatus.symbol)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(saveStatus.tone.color)
            .contentTransition(.symbolEffect(.replace))
            .animation(isReduceMotionEnabled ? nil : .easeOut(duration: 0.2), value: saveStatus)
    }

    private func openArtistPicker() {
        isArtistPickerOpen = true
    }

    @discardableResult
    private func recordSave(_ accepted: Bool) -> Bool {
        saveStatus = accepted ? .saved : .failed
        return accepted
    }

    private var api: some View {
        VStack(spacing: 14) {
            group("Metadata sources", "key", .accent) {
                // MusicBrainz needs no token; the public rate limit is a
                // property of the service, not app state.
                apiRow("MusicBrainz", "Public rate limit", .info, "Public")
                apiRow(
                    "Discogs",
                    discogsDetail.description,
                    discogsDetail.tone,
                    discogsDetail.badge
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var discogsDetail: (description: String, tone: Tone, badge: String) {
        switch settings.discogsState {
        case .noToken:
            ("No token configured", .neutral, "Not set")
        case .connected:
            ("Connected · token valid", .success, "Connected")
        case .tokenIssue:
            ("Token rejected — check credentials", .warning, "Issue")
        case .unverified:
            ("Token set · not verified yet", .info, "Unverified")
        }
    }

    private var advanced: some View {
        VStack(spacing: 14) {
            group("Scoring & verification", "slider.horizontal.3", .accent) {
                row("Release-year restore threshold", "Maximum year gap before restoring a release year.") {
                    Stepper(value: releaseYearRestoreThresholdBinding, in: 0 ... 100) {
                        Text("\(settings.releaseYearRestoreThresholdYears)y")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                    .frame(width: 92)
                    .disabled(setReleaseYearRestoreThresholdAction == nil)
                }
                row("Post-write verification", "Re-read each track after writing to confirm the tag landed.") {
                    TagPill(
                        text: settings.isPostWriteVerificationRequired ? "Required" : "Not configured",
                        tone: settings.isPostWriteVerificationRequired ? .success : .neutral,
                        dot: true
                    )
                }
            }
            group("Music metadata reads", "music.note.list", .info) {
                row(
                    "Bulk metadata threshold",
                    "Below this count, reads are targeted by Music database ID; at or above it, one bulk read is used."
                ) {
                    Stepper(
                        value: bulkThresholdBinding,
                        in: settings.metadataReads.bulkThresholdRange
                    ) {
                        Text("\(settings.metadataReads.bulkThreshold) tracks")
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                    .frame(width: 132)
                    .disabled(setBulkThresholdAction == nil)
                }
            }
            group("Diagnostics", "doc.text", .purple) {
                row("Log level", "Verbosity is controlled by macOS Unified Logging.") {
                    TagPill(text: "System", tone: .neutral)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var appearance: some View {
        VStack(spacing: 14) {
            group("Theme", "paintpalette", .accent) {
                row("Appearance", "DesignUI currently uses dark Ayu tokens.") {
                    Picker("", selection: appearanceModeBinding) {
                        ForEach(DesignAppearanceMode.supportedModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(setAppearanceModeAction == nil)
                }
                row("Ayu palette", "Current DesignUI color tokens.") {
                    HStack(spacing: 8) {
                        colorSwatch(Ayu.window, label: "Window")
                        colorSwatch(Ayu.card, label: "Card")
                        colorSwatch(Ayu.accent, label: "Accent")
                        colorSwatch(Ayu.info, label: "Info")
                    }
                }
            }
            group("Motion", "sparkles", .purple) {
                row("Fast animations", "Shorten motion timing in legacy workflow surfaces.") {
                    Toggle("", isOn: fastAnimationsBinding)
                        .labelsHidden()
                        .tint(Ayu.accent)
                        .disabled(setFastAnimationsAction == nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func group(
        _ title: String,
        _ symbol: String,
        _ tone: Tone,
        @ViewBuilder _ content: () -> some View
    ) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Image(systemName: symbol).foregroundStyle(tone.color)
                    Text(title).font(.system(size: 15, weight: .bold))
                }
                .padding(.bottom, 6)
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ desc: String, @ViewBuilder _ control: () -> some View) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ayu.fg)
                Text(desc).font(.system(size: 12)).foregroundStyle(Ayu.fg2)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider().overlay(Ayu.glassBorder), alignment: .bottom)
    }

    private func colorSwatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color)
                .frame(width: 34, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ayu.glassBorderStrong))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Ayu.fg2)
        }
    }

    private func apiRow(_ name: String, _ desc: String, _ tone: Tone, _ status: String) -> some View {
        row(name, desc) {
            HStack(spacing: 10) {
                TagPill(text: status, tone: tone, dot: true)
                BorderedButton(
                    title: status == "Connected" ? "Edit" : "Add token",
                    symbol: "key",
                    enabled: false
                )
            }
        }
    }
}

private enum SettingsSaveStatus {
    case automatic
    case saved
    case failed

    var label: String {
        switch self {
        case .automatic: "Changes save automatically"
        case .saved: "Saved"
        case .failed: "Couldn’t save"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "arrow.trianglehead.2.clockwise.rotate.90"
        case .saved: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tone: Tone {
        switch self {
        case .automatic: .neutral
        case .saved: .success
        case .failed: .warning
        }
    }
}
