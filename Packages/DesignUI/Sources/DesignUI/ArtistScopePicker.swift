import Foundation
import SwiftUI

struct ArtistScopeDraft: Equatable {
    private(set) var selected: [String]

    var isFullLibrary: Bool {
        selected.isEmpty
    }

    init(selected: [String]) {
        self.selected = []
        for artist in selected {
            let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedArtist.isEmpty, !contains(trimmedArtist) else { continue }
            self.selected.append(trimmedArtist)
        }
    }

    func contains(_ artist: String) -> Bool {
        selected.contains { $0.localizedCaseInsensitiveCompare(artist) == .orderedSame }
    }

    mutating func toggle(_ artist: String) {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArtist.isEmpty else { return }

        if let index = selected.firstIndex(where: {
            $0.localizedCaseInsensitiveCompare(trimmedArtist) == .orderedSame
        }) {
            selected.remove(at: index)
        } else {
            selected.append(trimmedArtist)
        }
    }

    func hasChanges(comparedTo artists: [String]) -> Bool {
        comparisonKeys(for: selected) != comparisonKeys(for: artists)
    }

    private func comparisonKeys(for artists: [String]) -> Set<String> {
        Set(artists.compactMap { artist in
            let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedArtist.isEmpty ? nil : trimmedArtist.lowercased(with: .current)
        })
    }
}

/// A staged, searchable multi-select for narrowing runs to library artists.
public struct ArtistScopePicker: View {
    let scope: DesignArtistScope
    let apply: ([String]) -> Bool

    @State private var draft: ArtistScopeDraft

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isFullScopePromptOpen = false
    @State private var saveIssue: String?

    /// Creates a picker whose changes remain local until `apply` accepts them.
    public init(scope: DesignArtistScope, apply: @escaping ([String]) -> Bool) {
        self.scope = scope
        self.apply = apply
        _draft = State(initialValue: ArtistScopeDraft(selected: scope.selected))
    }

    public var body: some View {
        VStack(spacing: 0) {
            pickerHeader
            Divider().overlay(Ayu.glassBorder)
            scopeSummary
            Divider().overlay(Ayu.glassBorder)
            artistList
            Divider().overlay(Ayu.glassBorder)
            actionBar
        }
        .background(Ayu.window)
        .modifier(PickerSizing())
        .alert("Use Full Library?", isPresented: $isFullScopePromptOpen) {
            Button("Cancel", role: .cancel) {}
            Button("Use Full Library", role: .destructive, action: applySelection)
        } message: {
            Text("No test artists will remain selected. Future runs will process the full music library.")
        }
    }

    private var pickerHeader: some View {
        HStack(spacing: 16) {
            Text("Choose Test Artists")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ayu.fg)

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Ayu.fgMuted)

                TextField("Search your library", text: $query)
                    .textFieldStyle(.plain)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Ayu.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Ayu.controlFillStrong, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Ayu.glassBorderStrong))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Ayu.surfaceRaised)
    }

    private var scopeSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.isFullLibrary ? "music.note.house" : "person.2.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(draft.isFullLibrary ? Ayu.warning : Ayu.fg2)
                .frame(width: 34, height: 34)
                .background(Ayu.controlFillStrong, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(scopeTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ayu.fg)
                Text(scopeDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(draft.isFullLibrary ? Ayu.warning : Ayu.fg2)
            }

            Spacer()
        }
        .padding(18)
        .background(Ayu.surfaceRaised)
    }

    private var artistList: some View {
        List {
            if !draft.selected.isEmpty {
                Section("Selected") {
                    ForEach(draft.selected, id: \.self) { artist in
                        artistRow(name: artist, trackCount: trackCount(for: artist), isSelected: true)
                    }
                }
            }

            Section("Library") {
                if let catalogIssue = scope.catalogIssue {
                    Label(catalogIssue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Ayu.warning)
                } else if availableOptions.isEmpty {
                    ContentUnavailableView(
                        emptyCatalogTitle,
                        systemImage: "music.mic",
                        description: Text(emptyCatalogDetail)
                    )
                } else {
                    ForEach(availableOptions) { option in
                        artistRow(name: option.name, trackCount: option.trackCount, isSelected: false)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Ayu.window)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let saveIssue {
                Label(saveIssue, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ayu.warning)
            } else if draft.isFullLibrary {
                Label("Full Library is a much broader processing scope", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ayu.warning)
            }

            Spacer()

            BorderedButton(title: "Cancel", action: dismiss.callAsFunction)
            PrimaryButton(
                title: "Apply",
                symbol: "checkmark",
                enabled: draft.hasChanges(comparedTo: scope.selected),
                action: requestApply
            )
        }
        .padding(18)
        .background(Ayu.surfaceRaised)
    }

    private var availableOptions: [DesignArtistOption] {
        scope.options(matching: query).filter { !draft.contains($0.name) }
    }

    private var scopeTitle: String {
        draft.isFullLibrary ? "Full Library" : "\(draft.selected.count) selected"
    }

    private var scopeDetail: String {
        if draft.isFullLibrary {
            return "Every artist can be processed on the next run."
        }
        return "Only these artists will be included in test runs."
    }

    private var emptyCatalogDetail: String {
        if scope.options.isEmpty {
            return "Load or sync the library, then try again."
        }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Remove a selection to return it to the library list."
        }
        return "Try a different artist name."
    }

    private var emptyCatalogTitle: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No Matching Artists"
        }
        return scope.options.isEmpty ? "No Artists Available" : "All Artists Selected"
    }

    private func trackCount(for artist: String) -> Int? {
        scope.options.first { option in
            option.name.localizedCaseInsensitiveCompare(artist) == .orderedSame
        }?.trackCount
    }

    private func artistRow(name: String, trackCount: Int?, isSelected: Bool) -> some View {
        Button {
            draft.toggle(name)
            saveIssue = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Ayu.accent : Ayu.fgMuted)

                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Ayu.fg)
                    .lineLimit(1)

                Spacer()

                if let trackCount {
                    Text(trackCount == 1 ? "1 track" : "\(trackCount) tracks")
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Ayu.fg2)
                } else {
                    Text("Not in current library")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Ayu.warning)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Ayu.controlFillStrong : Color.clear)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func requestApply() {
        guard draft.hasChanges(comparedTo: scope.selected) else { return }
        if draft.isFullLibrary, !scope.selected.isEmpty {
            isFullScopePromptOpen = true
        } else {
            applySelection()
        }
    }

    private func applySelection() {
        if apply(draft.selected) {
            dismiss()
        } else {
            saveIssue = "Couldn’t save this scope. Your previous selection is unchanged."
        }
    }
}

private struct PickerSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.presentationSizing(.form)
        } else {
            content
        }
    }
}
