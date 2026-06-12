// BrowseViewModel.swift — Data layer for Browse: artist grouping, search, filters, selection, sorting.

import AppKit
import Core
import Foundation
import os
import SharedUI
import SwiftUI

// MARK: - Data Models

struct ArtistGroup: Identifiable {
    let canonicalName: String
    let variants: [String]
    let albumCount: Int
    let totalTrackCount: Int
    let primaryGenre: String?
    let healthRatio: Double
    let lastModified: Date?

    var id: String {
        canonicalName
    }
}

struct AlbumSummary: Identifiable {
    let name: String
    let artist: String
    let year: Int?
    let trackCount: Int
    let primaryGenre: String?
    let healthRatio: Double

    var id: String {
        "\(artist)|\(name)"
    }
}

struct LetterSection: Identifiable {
    let letter: String
    let artists: [ArtistGroup]

    var id: String {
        letter
    }
}

struct AlbumIdentifier: Hashable {
    let albumName: String
    let artistName: String
}

// MARK: - Browse Filter

enum BrowseFilter: String, CaseIterable, Hashable {
    case missingGenre = "Missing Genre"
    case missingYear = "Missing Year"
    case recentlyAdded = "Recently Added"
    case updatedToday = "Updated Today"

    func matches(_ track: Track) -> Bool {
        switch self {
        case .missingGenre:
            return track.genre == nil || track.genre?.isEmpty == true
        case .missingYear:
            return track.year == nil
        case .recentlyAdded:
            guard let dateAdded = track.dateAdded else { return false }
            let days = Calendar.current.dateComponents(
                [.day], from: dateAdded, to: .now
            ).day ?? 999
            return days <= 7
        case .updatedToday:
            guard let lastModified = track.lastModified else { return false }
            return Calendar.current.isDateInToday(lastModified)
        }
    }
}

// MARK: - Sort Order

enum BrowseSortOrder: String, CaseIterable {
    case name = "Name"
    case trackCount = "Track Count"
    case tagCompletion = "Tag Completion %"
}

// MARK: - Search Results

struct BrowseSearchResults {
    let artists: [ArtistGroup]
    let albums: [AlbumSummary]
    let tracks: [Track]

    var isEmpty: Bool {
        artists.isEmpty && albums.isEmpty && tracks.isEmpty
    }
}

// MARK: - Browse View Model

/// Data layer for the Browse screen: artist grouping, search, filters, selection, sorting.
///
/// Uses `normalizeArtistForMatching()` from Core to group artist name variants
/// under a canonical name (most common spelling). Search runs off the main
/// thread to keep the UI responsive at 38K+ tracks.
@Observable @MainActor
final class BrowseViewModel {
    private let log = Logger(
        subsystem: "com.genreupdater.app",
        category: "BrowseViewModel"
    )

    // MARK: - Input

    var tracks: [Track] = [] {
        didSet { recomputeSections() }
    }

    // MARK: - Computed State

    private(set) var sections: [LetterSection] = []
    private(set) var searchResults: BrowseSearchResults?
    private(set) var filteredTrackCount: Int = 0

    // MARK: - UI State

    var searchText = ""
    var expandedArtists: Set<String> = []
    var selectedAlbum: AlbumIdentifier?
    var selectedItems: Set<String> = []
    var lastSelectedItem: String?
    var activeFilters: Set<BrowseFilter> = []
    var sortOrder: BrowseSortOrder = .name {
        didSet { recomputeSections() }
    }

    var cardLiftState: CardLiftState?
    var reduceMotion = false

    // MARK: - Selection

    var hasSelection: Bool {
        !selectedItems.isEmpty
    }
    var selectionCount: Int {
        selectedItems.count
    }

    // MARK: - All Artist Groups (pre-filter cache)

    private var allArtistGroups: [ArtistGroup] = []
    private var tracksByNormalizedArtist: [String: [Track]] = [:]

    // MARK: - Recompute Sections

    private func recomputeSections() {
        let grouped = Dictionary(grouping: tracks) { track in
            normalizeArtistForMatching(track.effectiveArtist)
        }
        tracksByNormalizedArtist = grouped

        var groups: [ArtistGroup] = grouped.map { _, artistTracks in
            buildArtistGroup(from: artistTracks)
        }

        // Apply filters
        if !activeFilters.isEmpty {
            groups = groups.compactMap { group in
                filterArtistGroup(group, tracks: grouped[normalizeArtistForMatching(group.canonicalName)] ?? [])
            }
        }

        // Sort
        groups = sortArtistGroups(groups)

        allArtistGroups = groups
        filteredTrackCount = groups.reduce(0) { $0 + $1.totalTrackCount }

        // Group into letter sections
        let byLetter = Dictionary(grouping: groups) { group in
            sectionLetter(for: group.canonicalName)
        }

        sections = byLetter.keys.sorted().map { letter in
            LetterSection(letter: letter, artists: byLetter[letter] ?? [])
        }
    }

    func applyFilters() {
        recomputeSections()
    }

    // MARK: - Artist Group Building

    private func buildArtistGroup(from artistTracks: [Track]) -> ArtistGroup {
        BrowseBuilders.buildArtistGroup(from: artistTracks)
    }

    // MARK: - Filter Application

    private func filterArtistGroup(_ group: ArtistGroup, tracks artistTracks: [Track]) -> ArtistGroup? {
        let matchingTracks = artistTracks.filter { track in
            activeFilters.allSatisfy { $0.matches(track) }
        }
        guard !matchingTracks.isEmpty else { return nil }
        return buildArtistGroup(from: matchingTracks)
    }

    // MARK: - Sorting

    private func sortArtistGroups(_ groups: [ArtistGroup]) -> [ArtistGroup] {
        switch sortOrder {
        case .name:
            groups.sorted {
                $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending
            }
        case .trackCount:
            groups.sorted { $0.totalTrackCount > $1.totalTrackCount }
        case .tagCompletion:
            groups.sorted { $0.healthRatio > $1.healthRatio }
        }
    }

    // MARK: - Search

    func updateSearchResults() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }

        let allTracks = tracks
        let results = await Task.detached(priority: .userInitiated) {
            var matchedArtistKeys: Set<String> = []
            var matchedAlbumKeys: Set<String> = []
            var matchedTracks: [Track] = []

            for track in allTracks {
                if track.effectiveArtist.localizedStandardContains(query) {
                    matchedArtistKeys.insert(
                        normalizeArtistForMatching(track.effectiveArtist)
                    )
                }
                if track.album.localizedStandardContains(query) {
                    let key = "\(track.effectiveArtist)|\(track.album)"
                    matchedAlbumKeys.insert(key)
                }
                if track.name.localizedStandardContains(query) {
                    matchedTracks.append(track)
                }
            }

            // Build artist groups for matched artists
            let artistGrouped = Dictionary(grouping: allTracks) {
                normalizeArtistForMatching($0.effectiveArtist)
            }
            let artists: [ArtistGroup] = matchedArtistKeys.compactMap { key in
                guard let artistTracks = artistGrouped[key] else { return nil }
                return BrowseBuilders.buildArtistGroup(from: artistTracks)
            }.sorted {
                $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending
            }

            // Build album summaries for matched albums
            let albumGrouped = Dictionary(grouping: allTracks) {
                "\($0.effectiveArtist)|\($0.album)"
            }
            let albums: [AlbumSummary] = matchedAlbumKeys.compactMap { key in
                guard let albumTracks = albumGrouped[key] else { return nil }
                return BrowseBuilders.buildAlbumSummary(from: albumTracks)
            }.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            return BrowseSearchResults(
                artists: artists,
                albums: albums,
                tracks: matchedTracks
            )
        }.value

        searchResults = results
    }

    // MARK: - Album Queries

    func albumsForArtist(_ artistName: String) -> [AlbumSummary] {
        let key = normalizeArtistForMatching(artistName)
        guard let artistTracks = tracksByNormalizedArtist[key] else { return [] }

        let grouped = Dictionary(grouping: artistTracks) { $0.album }
        return grouped.map { _, albumTracks in
            BrowseBuilders.buildAlbumSummary(from: albumTracks)
        }
        .sorted { lhs, rhs in
            switch (lhs.year, rhs.year) {
            case let (left?, right?): left > right
            case (nil, _?): false
            case (_?, nil): true
            case (nil, nil):
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func albumSummary(for album: AlbumIdentifier) -> AlbumSummary? {
        albumsForArtist(album.artistName).first { $0.name == album.albumName }
    }

    func tracksForAlbum(_ album: AlbumIdentifier) -> [Track] {
        let key = normalizeArtistForMatching(album.artistName)
        guard let artistTracks = tracksByNormalizedArtist[key] else { return [] }

        return artistTracks
            .filter { $0.album == album.albumName }
            .sorted { lhs, rhs in
                let lhsPos = lhs.originalPosition ?? Int.max
                let rhsPos = rhs.originalPosition ?? Int.max
                return lhsPos < rhsPos
            }
    }

    // MARK: - Album Navigation

    func nextAlbum(after current: AlbumIdentifier) -> AlbumIdentifier? {
        let albums = albumsForArtist(current.artistName)
        guard let index = albums.firstIndex(where: { $0.name == current.albumName }),
              index + 1 < albums.count
        else { return nil }
        let next = albums[index + 1]
        return AlbumIdentifier(albumName: next.name, artistName: current.artistName)
    }

    func previousAlbum(before current: AlbumIdentifier) -> AlbumIdentifier? {
        let albums = albumsForArtist(current.artistName)
        guard let index = albums.firstIndex(where: { $0.name == current.albumName }),
              index > 0
        else { return nil }
        let previous = albums[index - 1]
        return AlbumIdentifier(albumName: previous.name, artistName: current.artistName)
    }

    // MARK: - Selection

    func handleRowClick(itemID: String, allVisibleIDs: [String]) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []

        if flags.contains(.command) {
            // Cmd+click: toggle individual selection
            if selectedItems.contains(itemID) {
                selectedItems.remove(itemID)
            } else {
                selectedItems.insert(itemID)
            }
            lastSelectedItem = itemID
        } else if flags.contains(.shift), let lastSelected = lastSelectedItem {
            // Shift+click: range selection
            guard let startIndex = allVisibleIDs.firstIndex(of: lastSelected),
                  let endIndex = allVisibleIDs.firstIndex(of: itemID)
            else {
                selectedItems.insert(itemID)
                lastSelectedItem = itemID
                return
            }
            let range = min(startIndex, endIndex) ... max(startIndex, endIndex)
            for index in range {
                selectedItems.insert(allVisibleIDs[index])
            }
            lastSelectedItem = itemID
        }
    }

    func handleCheckboxToggle(_ itemID: String) {
        if selectedItems.contains(itemID) {
            selectedItems.remove(itemID)
        } else {
            selectedItems.insert(itemID)
        }
        lastSelectedItem = itemID
    }

    func toggleExpanded(_ artistName: String) {
        if expandedArtists.contains(artistName) {
            expandedArtists.remove(artistName)
        } else {
            expandedArtists.insert(artistName)
        }
    }

    func clearSelection() {
        selectedItems.removeAll()
        lastSelectedItem = nil
    }

    // MARK: - Card Lift

    func liftCard(sourceID: String, contentType: CardContentType, sourceFrame: CGRect) {
        cardLiftState = CardLiftState(
            sourceID: sourceID,
            contentType: contentType,
            phase: reduceMotion ? .lifted : .pressing,
            sourceFrame: sourceFrame
        )

        guard !reduceMotion else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard cardLiftState?.sourceID == sourceID else { return }
            withAnimation(Motion.cardLiftSpring) {
                cardLiftState?.phase = .lifted
            }
        }
    }

    func dismissCardLift() {
        guard let currentState = cardLiftState else { return }

        // Cascade: return to parent card
        if let parentSourceID = currentState.parentSourceID,
           let parentContentType = currentState.parentContentType {
            let parentFrame = currentState.parentSourceFrame ?? .zero
            cardLiftState = CardLiftState(
                sourceID: parentSourceID,
                contentType: parentContentType,
                phase: .lifted,
                sourceFrame: parentFrame
            )
            return
        }

        // Full dismiss
        guard !reduceMotion else {
            cardLiftState = nil
            return
        }

        withAnimation(Motion.cardLiftSpring) {
            cardLiftState?.phase = .dismissing
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            cardLiftState = nil
        }
    }

    func cascadeToAlbum(album: AlbumSummary, sourceFrame: CGRect) {
        let parentSourceID = cardLiftState?.sourceID
        let parentContentType = cardLiftState?.contentType
        let parentSourceFrame = cardLiftState?.sourceFrame

        cardLiftState = CardLiftState(
            sourceID: album.id,
            contentType: .album(name: album.name, artistName: album.artist),
            phase: reduceMotion ? .lifted : .pressing,
            sourceFrame: sourceFrame,
            parentSourceID: parentSourceID,
            parentContentType: parentContentType,
            parentSourceFrame: parentSourceFrame
        )

        guard !reduceMotion else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard cardLiftState?.sourceID == album.id else { return }
            withAnimation(Motion.cardLiftSpring) {
                cardLiftState?.phase = .lifted
            }
        }
    }

    func artistGroupForCardLift(_ name: String) -> ArtistGroup? {
        let key = normalizeArtistForMatching(name)
        return allArtistGroups.first {
            normalizeArtistForMatching($0.canonicalName) == key
        }
    }

    func tracksForArtist(_ artistName: String) -> [Track] {
        let key = normalizeArtistForMatching(artistName)
        return tracksByNormalizedArtist[key] ?? []
    }

    // MARK: - Helpers

    private func sectionLetter(for name: String) -> String {
        guard let first = name.first else { return "#" }
        let upper = String(first).uppercased()
        return upper.first?.isLetter == true ? upper : "#"
    }
}
