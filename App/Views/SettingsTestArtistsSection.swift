// SettingsTestArtistsSection.swift — batch artist-list controls.

import AppKit
import SwiftUI

struct SettingsTestArtistsSection: View {
    let dependencies: AppDependencies

    @State private var newTestArtist = ""
    @State private var importStatus = ""

    var body: some View {
        Section {
            if dependencies.config.development.testArtists.isEmpty {
                Text("No test artists configured")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(dependencies.config.development.testArtists, id: \.self) { artist in
                HStack {
                    Text(artist)

                    Spacer()

                    Button {
                        removeTestArtist(artist)
                    } label: {
                        Image(systemName: "trash")
                            .accessibilityLabel("Remove \(artist)")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Remove \(artist)")
                }
            }
            .onDelete { offsets in
                dependencies.config.development.testArtists.remove(atOffsets: offsets)
                saveConfiguration(dependencies)
            }

            HStack {
                TextField("Artist", text: $newTestArtist)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addTestArtist() }
                    .disabled(trimmedTestArtist.isEmpty)
                Button {
                    importTestArtistsFromFile()
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        } header: {
            Text("Test Artists")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When configured, library refreshes are limited to these artists for safer test-mode runs.")
                if !importStatus.isEmpty {
                    Text(importStatus)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var trimmedTestArtist: String {
        newTestArtist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTestArtist() {
        let addedCount = addTestArtists([trimmedTestArtist])
        newTestArtist = ""
        importStatus = addedCount == 0 ? "Artist already exists" : ""
    }

    private func removeTestArtist(_ artist: String) {
        let previousCount = dependencies.config.development.testArtists.count
        dependencies.config.development.testArtists.removeAll { existing in
            existing.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }

        if dependencies.config.development.testArtists.count < previousCount {
            importStatus = ""
            saveConfiguration(dependencies)
        }
    }

    private func importTestArtistsFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Import Artist List"
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            let artists = contents
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let addedCount = addTestArtists(artists)
            importStatus = addedCount == 0
                ? "No new artists imported"
                : "Imported \(addedCount) artists"
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func addTestArtists(_ artists: [String]) -> Int {
        var addedCount = 0
        for artist in artists {
            let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedArtist.isEmpty else { continue }

            let alreadyExists = dependencies.config.development.testArtists.contains { existing in
                existing.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmedArtist) == .orderedSame
            }
            guard !alreadyExists else { continue }

            dependencies.config.development.testArtists.append(trimmedArtist)
            addedCount += 1
        }

        if addedCount > 0 {
            saveConfiguration(dependencies)
        }
        return addedCount
    }
}
