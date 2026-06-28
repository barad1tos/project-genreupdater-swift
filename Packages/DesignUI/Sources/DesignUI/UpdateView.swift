import SwiftUI

struct UpdateView: View {
    @Bindable var model: AppModel
    @State private var behavior = "both"
    @State private var minConf = 50.0
    @State private var confirm = false

    private var shown: [Change] {
        model.data.changes.filter {
            $0.conf * 100 >= minConf && (behavior == "both" || $0.type.rawValue == behavior)
        }
    }

    var body: some View {
        let dr = model.data.dryRun
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Text("Update").font(.system(size: 24, weight: .heavy))
                TagPill(
                    text: model.dryRun ? "Dry run — preview only" : "Live write mode",
                    tone: model.dryRun ? .info : .accent,
                    dot: true
                )
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "eye").foregroundStyle(Ayu.info)
                        Text("Dry Run Report").font(.system(size: 16, weight: .bold))
                        Text("· full library scope").font(.system(size: 12.5)).foregroundStyle(Ayu.fg2)
                    }
                    HStack(spacing: 36) {
                        stat("\(dr.changes)", "Changes", .accent)
                        stat("\(dr.tracks)", "Tracks", .neutral)
                        stat("\(dr.averageConfidence)%", "Avg confidence", .success)
                        Divider().frame(height: 38).overlay(Ayu.glassBorder)
                        HStack(spacing: 9) {
                            TagPill(text: "\(dr.genre) Genre", tone: .purple, dot: true)
                            TagPill(text: "\(dr.year) Year", tone: .info, dot: true)
                        }
                    }
                    Divider().overlay(Ayu.glassBorder)
                    HStack(spacing: 22) {
                        HStack(spacing: 10) {
                            Text("Apply to").font(.system(size: 12.5)).foregroundStyle(Ayu.fg2)
                            Picker("", selection: $behavior) {
                                Text("Genre").tag("genre")
                                Text("Year").tag("year")
                                Text("Both").tag("both")
                            }.pickerStyle(.segmented).frame(width: 200)
                        }
                        HStack(spacing: 10) {
                            Text("Preview only").font(.system(size: 12.5)).foregroundStyle(Ayu.fg2)
                            Toggle("", isOn: $model.dryRun).labelsHidden().tint(Ayu.accent)
                        }
                        HStack(spacing: 10) {
                            Text("Min confidence").font(.system(size: 12.5)).foregroundStyle(Ayu.fg2)
                            Slider(value: $minConf, in: 30 ... 100).frame(width: 160).tint(Ayu.accent)
                            Text("\(Int(minConf))%").font(.system(size: 13, weight: .bold).monospacedDigit())
                                .frame(width: 40)
                        }
                        Spacer()
                    }
                }
            }

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(shown.count) proposed changes shown").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Ayu.fg2)
                        Spacer()
                    }
                    .padding(.horizontal, 18).padding(.vertical, 13)
                    Divider().overlay(Ayu.glassBorder)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(shown) { change in
                                HStack(spacing: 13) {
                                    Image(systemName: change.type.symbol).foregroundStyle(change.type.tone.color)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(change.track).font(.system(size: 13.5)).foregroundStyle(Ayu.fg)
                                        Text(change.artist).font(.system(size: 11.5)).foregroundStyle(Ayu.fg2)
                                    }
                                    Spacer()
                                    DiffRow(old: change.old, new: change.new)
                                    ConfidenceBadge(conf: change.conf)
                                }
                                .padding(.horizontal, 18).padding(.vertical, 11)
                                Divider().overlay(Ayu.glassBorder)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // action bar
            GlassCard(padding: 12) {
                HStack(spacing: 12) {
                    if confirm {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Ayu.warning)
                        Text("Write \(shown.count) genre/year tags to Music.app?").font(.system(
                            size: 13,
                            weight: .semibold
                        ))
                        Spacer()
                        BorderedButton(title: "Cancel") { confirm = false }
                        PrimaryButton(title: "Confirm write", symbol: "checkmark") {
                            confirm = false
                            model.navigate(to: .activity)
                        }
                    } else {
                        Image(systemName: model.dryRun ? "eye" : "pencil")
                            .foregroundStyle(model.dryRun ? Ayu.info : Ayu.accent)
                        Text(model.dryRun ? "Dry run won’t modify your library. Switch off Preview only to write tags."
                            : "\(shown.count) tags will be written to Music. A revert CSV is saved first.")
                            .font(.system(size: 13)).foregroundStyle(Ayu.fg2)
                        Spacer()
                        BorderedButton(title: "Close") { model.navigate(to: .activity) }
                        PrimaryButton(
                            title: model.dryRun ? "Stage write" : "Apply \(shown.count)",
                            symbol: model.dryRun ? "checklist" : "checkmark"
                        ) {
                            model.dryRun ? (model.dryRun = false) : (confirm = true)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 1320, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ayu.window)
        .navigationTitle("Update")
    }

    private func stat(_ value: String, _ label: String, _ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.rounded(26, .heavy)).foregroundStyle(tone == .neutral ? Ayu.fg : tone.color)
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Ayu.fg2)
        }
    }
}
