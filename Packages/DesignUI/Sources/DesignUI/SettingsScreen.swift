import SwiftUI

struct SettingsScreen: View {
    @Bindable var model: AppModel
    @State private var tab = "general"
    @State private var behavior = "both"
    @State private var minConf = 70.0
    @State private var autoScan = true
    @State private var restore = 40.0
    @State private var verify = true
    @State private var logLevel = "info"
    @State private var testArtists = ["Aphex Twin", "Boards of Canada"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text("Settings").font(.system(size: 24, weight: .heavy))
                Picker("", selection: $tab) {
                    Text("General").tag("general"); Text("API & Cache").tag("api"); Text("Advanced").tag("advanced")
                }.pickerStyle(.segmented).frame(width: 320)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case "general": general
                    case "api": api
                    default: advanced
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ayu.window)
        .navigationTitle("Settings")
    }

    private var general: some View {
        VStack(spacing: 14) {
            group("Update behavior", "wand.and.stars", .accent) {
                row("Fields to update", "Which metadata GenreUpdater writes during a run.") {
                    Picker("", selection: $behavior) {
                        Text("Genre").tag("genre"); Text("Year").tag("year"); Text("Both").tag("both")
                    }.pickerStyle(.segmented).frame(width: 220)
                }
                row("Safe mode (dry-run)", "Always preview proposed changes before any tag is written.") {
                    Toggle("", isOn: $model.dryRun).labelsHidden().tint(Ayu.accent)
                }
                row("Minimum confidence", "Reject suggestions below this score.") {
                    HStack { Slider(value: $minConf, in: 30...100).frame(width: 160).tint(Ayu.accent)
                        Text("\(Int(minConf))%").font(.system(size: 13, weight: .bold).monospacedDigit()) }
                }
            }
            group("Schedule", "clock", .info) {
                row("Automatic scan", "Re-scan the library on a daily schedule.") {
                    Toggle("", isOn: $autoScan).labelsHidden().tint(Ayu.accent)
                }
                row("Scan time", "Local time for the daily auto-scan.") {
                    TagPill(text: "Daily · \(model.snapshot.nextRun)", tone: .neutral)
                }
            }
            group("Test artists scope", "music.note.list", .purple) {
                row("Limit runs to these artists", "Leave empty to process the full library.") {
                    HStack(spacing: 7) {
                        ForEach(testArtists, id: \.self) { a in TagPill(text: a, tone: .purple) }
                        BorderedButton(title: "Add", symbol: "plus") {}
                    }
                }
            }
        }
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
                    HStack { TagPill(text: "218 MB", tone: .neutral); BorderedButton(title: "Clear cache") {} }
                }
                row("Track ID mapping", "Persistent map between MusicKit IDs and writable tracks.") {
                    TagPill(text: "42,318 mapped", tone: .success, dot: true)
                }
            }
        }
    }

    private var advanced: some View {
        VStack(spacing: 14) {
            group("Scoring & verification", "slider.horizontal.3", .accent) {
                row("Release-year restore threshold", "Confidence needed to overwrite an existing year.") {
                    HStack { Slider(value: $restore, in: 0...100).frame(width: 160).tint(Ayu.accent)
                        Text("\(Int(restore))%").font(.system(size: 13, weight: .bold).monospacedDigit()) }
                }
                row("Post-write verification", "Re-read each track after writing to confirm the tag landed.") {
                    Toggle("", isOn: $verify).labelsHidden().tint(Ayu.accent)
                }
            }
            group("Diagnostics", "doc.text", .purple) {
                row("Log level", "Verbosity of the run log written to disk.") {
                    Picker("", selection: $logLevel) {
                        Text("Error").tag("error"); Text("Info").tag("info"); Text("Debug").tag("debug")
                    }.pickerStyle(.segmented).frame(width: 220)
                }
            }
        }
    }

    private func group<C: View>(_ title: String, _ symbol: String, _ tone: Tone, @ViewBuilder _ content: () -> C) -> some View {
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
    }

    private func row<C: View>(_ title: String, _ desc: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Ayu.fg)
                Text(desc).font(.system(size: 12)).foregroundStyle(Ayu.fg2)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 12)
        .overlay(Divider().overlay(Ayu.glassBorder), alignment: .bottom)
    }

    private func apiRow(_ name: String, _ desc: String, _ tone: Tone, _ status: String) -> some View {
        row(name, desc) {
            HStack(spacing: 10) {
                TagPill(text: status, tone: tone, dot: true)
                BorderedButton(title: status == "Connected" ? "Edit" : "Add token", symbol: "key") {}
            }
        }
    }
}
