import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: AppModel
    var setDryRunAction: ((Bool) -> Bool)?
    var setUpdateBehaviorAction: ((DesignUpdateBehavior) -> Bool)?
    var setMinimumConfidenceAction: ((Double) -> Bool)?
    var setReleaseYearRestoreThresholdAction: ((Int) -> Bool)?
    @State private var tab = "general"
    @State private var stagedMinimumConfidencePercent: Double?
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
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "general": general
                    case "api": api
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
                    .frame(width: 220)
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
                    HStack(spacing: 7) {
                        if settings.testArtists.isEmpty {
                            TagPill(text: "Full library", tone: .neutral)
                        } else {
                            ForEach(settings.testArtists, id: \.self) { artist in
                                TagPill(text: artist, tone: .purple)
                            }
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
