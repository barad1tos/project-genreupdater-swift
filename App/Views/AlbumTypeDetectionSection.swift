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
                mutateConfiguration(dependencies) { configuration in
                    configuration.albumTypeDetection[keyPath: keyPath].remove(atOffsets: offsets)
                }
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
        if mutateConfiguration(dependencies, { configuration in
            configuration.albumTypeDetection[keyPath: keyPath].append(trimmed)
        }) {
            newValue.wrappedValue = ""
        }
    }
}
