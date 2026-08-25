// SettingsTestArtistsSection.swift — batch artist-list controls.

import AppKit
import Core
import DesignUI
import Services
import SwiftUI

struct SettingsTestArtistsSection: View {
    let dependencies: AppDependencies

    @State private var artistCatalogFeed = ArtistCatalogFeed()
    @State private var importStatus = ""
    @State private var isArtistPickerOpen = false

    var body: some View {
        Section {
            if dependencies.config.development.testArtists.isEmpty {
                Label("Full Library", systemImage: "music.note.house")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(dependencies.config.development.testArtists, id: \.self) { artist in
                Text(artist)
            }

            HStack {
                Button {
                    isArtistPickerOpen = true
                } label: {
                    Label("Choose Artists…", systemImage: "person.2")
                }
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
                if let catalogIssue = artistScope.catalogIssue {
                    Text(catalogIssue)
                }
                if !importStatus.isEmpty {
                    Text(importStatus)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .task {
            await dependencies.refreshArtistCatalog()
        }
        .task { await artistCatalogFeed.observe(dependencies.projectionStore) }
        .sheet(isPresented: $isArtistPickerOpen) {
            ArtistScopePicker(scope: artistScope, apply: applyTestArtists)
        }
    }

    private var artistScope: DesignArtistScope {
        ArtistCatalogAdapter.makeScope(
            selected: dependencies.config.development.testArtists,
            settingsRevision: dependencies.config.revision,
            projection: artistCatalogFeed.projection
        )
    }

    private func applyTestArtists(_ change: ArtistScopeChange) -> ArtistScopeSaveResult {
        let result = saveArtistScope(change, dependencies: dependencies)
        switch result {
        case .accepted:
            importStatus = "Saved"
        case .stale:
            importStatus = "Settings changed elsewhere. Review the current artist list."
        case .failed:
            importStatus = "Could not save the artist list"
        }
        return result
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
