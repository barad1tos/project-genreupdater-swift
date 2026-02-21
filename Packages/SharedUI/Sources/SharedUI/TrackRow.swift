// TrackRow.swift — Compact track display for list views
// Extracted from App/Views/MainView.swift to SharedUI for reuse.

import Core
import SwiftUI

/// Single-line track display showing name, artist, and album.
public struct TrackRow: View {
    public let track: Track

    public init(track: Track) {
        self.track = track
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.name)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !track.album.isEmpty {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.quaternary)

                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
