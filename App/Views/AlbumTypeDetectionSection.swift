// AlbumTypeDetectionSection.swift - album type detection settings.

import Core
import SwiftUI

struct AlbumTypeDetectionSection: View {
    let dependencies: AppDependencies

    @State private var newSpecialPattern = ""
    @State private var newCompilationPattern = ""
    @State private var newReissuePattern = ""
    @State private var newSoundtrackPattern = ""
    @State private var newVariousArtistName = ""
    @State private var ruleRemovalFlow = MetadataRuleRemovalFlow()

    var body: some View {
        Group {
            patternSection(
                "Special album patterns",
                group: .specialAlbums,
                keyPath: \.specialPatterns,
                newValue: $newSpecialPattern,
                placeholder: "archive"
            )
            patternSection(
                "Compilation patterns",
                group: .compilations,
                keyPath: \.compilationPatterns,
                newValue: $newCompilationPattern,
                placeholder: "greatest hits"
            )
            patternSection(
                "Reissue patterns",
                group: .reissues,
                keyPath: \.reissuePatterns,
                newValue: $newReissuePattern,
                placeholder: "anniversary"
            )
            patternSection(
                "Soundtrack patterns",
                group: .soundtracks,
                keyPath: \.soundtrackPatterns,
                newValue: $newSoundtrackPattern,
                placeholder: "original score"
            )
            patternSection(
                "Various artists names",
                group: .variousArtists,
                keyPath: \.variousArtistsNames,
                newValue: $newVariousArtistName,
                placeholder: "Various Artists"
            )
        }
        .confirmRuleRemoval($ruleRemovalFlow, apply: removeRules)
    }

    private func patternSection(
        _ title: String,
        group: MetadataRuleGroup,
        keyPath: WritableKeyPath<AlbumTypeDetectionConfig, [String]>,
        newValue: Binding<String>,
        placeholder: String
    ) -> some View {
        let snapshot = values(for: keyPath)

        return Section(title) {
            ForEach(Array(snapshot.enumerated()), id: \.offset) { _, value in
                Text(value)
            }
            .onDelete { offsets in
                guard let removal = MetadataRuleRemoval(
                    group: group,
                    snapshot: snapshot,
                    offsets: offsets
                ) else { return }
                ruleRemovalFlow.request(removal, apply: removeRules)
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
        let status = mutateConfiguration(dependencies) { configuration in
            configuration.albumTypeDetection[keyPath: keyPath].append(trimmed)
        }
        if status == .accepted {
            newValue.wrappedValue = ""
        }
    }

    private func removeRules(_ removal: MetadataRuleRemoval) -> RuleRemovalOutcome {
        guard let updated = removal.removing(from: dependencies.config) else { return .stale }
        return RuleRemovalOutcome(status: mutateConfiguration(dependencies) { $0 = updated })
    }
}
