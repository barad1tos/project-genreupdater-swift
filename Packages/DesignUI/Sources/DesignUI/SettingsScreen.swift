import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: AppModel
    var setDryRunAction: ((Bool) -> Bool)?
    var setUpdateBehaviorAction: ((DesignUpdateBehavior) -> Bool)?
    var setMinimumConfidenceAction: ((Double) -> Bool)?
    var setReleaseYearRestoreThresholdAction: ((Int) -> Bool)?
    var setTestArtistsAction: (([String]) -> Bool)?
    var setAppearanceModeAction: ((DesignAppearanceMode) -> Bool)?
    var setFastAnimationsAction: ((Bool) -> Bool)?
    @State private var tab = "general"
    @State private var stagedMinimumConfidencePercent: Double?
    @State private var newTestArtist = ""
    @State private var testArtistsMessage: String?
    @State private var isEditingMinimumConfidence = false
    @State private var minimumConfidenceCommitTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Settings").font(.system(size: 24, weight: .heavy))
                Picker("", selection: $tab) {
                    Text("General").tag("general")
                    Text("API & Cache").tag("api")
                    Text("Advanced").tag("advanced")
                    Text("Appearance").tag("appearance")
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "general": general
                    case "api": api
                    case "appearance": appearance
                    default: advanced
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
            let accepted = setDryRunAction?(isDryRun) ?? true
            if !accepted {
                model.dryRun = previousValue
            }
        }
    }

    private var updateBehaviorBinding: Binding<DesignUpdateBehavior> {
        Binding {
            settings.updateBehavior
        } set: { behavior in
            _ = setUpdateBehaviorAction?(behavior)
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
            _ = setReleaseYearRestoreThresholdAction?(years)
        }
    }

    private var appearanceModeBinding: Binding<DesignAppearanceMode> {
        Binding {
            DesignAppearanceMode.supportedModes.contains(settings.appearanceMode) ? settings.appearanceMode : .dark
        } set: { mode in
            _ = setAppearanceModeAction?(mode)
        }
    }

    private var fastAnimationsBinding: Binding<Bool> {
        Binding {
            settings.isFastAnimationsEnabled
        } set: { isEnabled in
            _ = setFastAnimationsAction?(isEnabled)
        }
    }

    private var trimmedTestArtist: String {
        newTestArtist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTestArtist() {
        guard !trimmedTestArtist.isEmpty else { return }
        let alreadyExists = settings.testArtists.contains { artist in
            artist.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(trimmedTestArtist) == .orderedSame
        }
        guard !alreadyExists else {
            testArtistsMessage = "Artist already exists"
            return
        }

        guard setTestArtistsAction?(settings.testArtists + [trimmedTestArtist]) ?? false else {
            testArtistsMessage = "Could not save artist scope"
            return
        }
        newTestArtist = ""
        testArtistsMessage = nil
    }

    private func removeTestArtist(_ artist: String) {
        guard let artistIndex = settings.testArtists.firstIndex(of: artist) else { return }
        var updatedArtists = settings.testArtists
        updatedArtists.remove(at: artistIndex)
        if setTestArtistsAction?(updatedArtists) ?? false {
            testArtistsMessage = nil
        } else {
            testArtistsMessage = "Could not save artist scope"
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
                }
                row("Minimum confidence", "Reject suggestions below this score.") {
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
                    TagPill(text: "Manual trigger", tone: .neutral)
                }
                row("Scan cadence", "Next scheduled automatic run, when available.") {
                    TagPill(text: model.snapshot.nextRun, tone: .neutral)
                }
            }
            group("Test artists scope", "music.note.list", .purple) {
                row("Limit runs to these artists", "Leave empty to process the full library.") {
                    VStack(alignment: .trailing, spacing: 8) {
                        if settings.testArtists.isEmpty {
                            TagPill(text: "Full library", tone: .neutral)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 7) {
                                    ForEach(settings.testArtists, id: \.self) { artist in
                                        testArtistToken(artist)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        HStack(spacing: 8) {
                            TextField("Artist", text: $newTestArtist)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Ayu.controlFill, in: .rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ayu.glassBorder))
                                .frame(minWidth: 120, idealWidth: 220, maxWidth: .infinity)
                                .onSubmit(addTestArtist)

                            Button(action: addTestArtist) {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Ayu.onAccent)
                            .frame(width: 28, height: 28)
                            .background(Ayu.accent, in: Circle())
                            .disabled(trimmedTestArtist.isEmpty || setTestArtistsAction == nil)
                            .opacity(trimmedTestArtist.isEmpty || setTestArtistsAction == nil ? 0.45 : 1)
                            .help("Add artist")
                        }

                        if let testArtistsMessage {
                            Text(testArtistsMessage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Ayu.warning)
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
        _ = setMinimumConfidenceAction?(stagedMinimumConfidencePercent)
        self.stagedMinimumConfidencePercent = nil
    }

    private func testArtistToken(_ artist: String) -> some View {
        HStack(spacing: 5) {
            Text(artist)
                .lineLimit(1)
            Button {
                removeTestArtist(artist)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ayu.fg2)
            .disabled(setTestArtistsAction == nil)
            .help("Remove \(artist)")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(Ayu.purple)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Ayu.purple.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(Ayu.purple.opacity(0.34)))
    }

    private var api: some View {
        VStack(spacing: 14) {
            group("Metadata sources", "key", .accent) {
                apiRow("MusicBrainz", "Public rate limit", .info, "Public")
                apiRow("Discogs", "Connected · token valid", .success, "Connected")
                apiRow("Apple Music API", "No token set", .warning, "Not set")
            }
            group("Cache", "externaldrive", .info) {
                row("Album-year cache", "Resolved release years cached to avoid repeat lookups.") {
                    HStack {
                        TagPill(text: "218 MB", tone: .neutral)
                        BorderedButton(title: "Clear cache", enabled: false)
                    }
                }
                row("Track ID mapping", "Persistent map between MusicKit IDs and writable tracks.") {
                    TagPill(text: "42,318 mapped", tone: .success, dot: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
