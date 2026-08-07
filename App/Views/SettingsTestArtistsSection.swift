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
                mutateConfiguration(dependencies) {
                    $0.development.testArtists.remove(atOffsets: offsets)
                }
            }

            HStack {
                TextField("Artist", text: $newTestArtist)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTestArtist)
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
        switch addTestArtists([trimmedTestArtist]) {
        case .added:
            newTestArtist = ""
            importStatus = ""
        case .nothingNew:
            newTestArtist = ""
            importStatus = "Artist already exists"
        case .saveFailed:
            importStatus = "Could not save the artist list"
        }
    }

    private func removeTestArtist(_ artist: String) {
        let hasMatch = dependencies.config.development.testArtists.contains { existing in
            existing.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }
        guard hasMatch else { return }
        importStatus = ""
        mutateConfiguration(dependencies) {
            $0.development.testArtists.removeAll { existing in
                existing.localizedCaseInsensitiveCompare(artist) == .orderedSame
            }
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
            switch addTestArtists(artists) {
            case let .added(count):
                importStatus = "Imported \(count) artists"
            case .nothingNew:
                importStatus = "No new artists imported"
            case .saveFailed:
                importStatus = "Import failed: could not save the artist list"
            }
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private enum ArtistAddOutcome {
        case added(Int)
        case nothingNew
        case saveFailed
    }

    private func addTestArtists(_ artists: [String]) -> ArtistAddOutcome {
        var additions: [String] = []
        for artist in artists {
            let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedArtist.isEmpty else { continue }

            let alreadyExists = (dependencies.config.development.testArtists + additions).contains { existing in
                existing.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmedArtist) == .orderedSame
            }
            guard !alreadyExists else { continue }

            additions.append(trimmedArtist)
        }

        guard !additions.isEmpty else { return .nothingNew }
        let status = mutateConfiguration(dependencies) {
            $0.development.testArtists.append(contentsOf: additions)
        }
        return status == .accepted ? .added(additions.count) : .saveFailed
    }
}
