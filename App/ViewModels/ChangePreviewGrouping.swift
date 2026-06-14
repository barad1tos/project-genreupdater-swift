// ChangePreviewGrouping.swift -- stable grouping for preview rows.

import Services

struct ChangePreviewGroupKey: Hashable {
    let artist: String
    let album: String

    var displayTitle: String {
        "\(artist) — \(album)"
    }
}

struct ChangePreviewGroup: Identifiable {
    let key: ChangePreviewGroupKey
    let changes: [ProposedChange]

    var id: ChangePreviewGroupKey {
        key
    }
}

enum ChangePreviewGrouping {
    static func groups(from changes: [ProposedChange]) -> [ChangePreviewGroup] {
        let grouped = Dictionary(grouping: changes) { change in
            ChangePreviewGroupKey(
                artist: change.track.artist,
                album: change.track.album
            )
        }

        return grouped
            .map { ChangePreviewGroup(key: $0.key, changes: $0.value) }
            .sorted {
                $0.key.displayTitle.localizedCaseInsensitiveCompare($1.key.displayTitle) == .orderedAscending
            }
    }
}
