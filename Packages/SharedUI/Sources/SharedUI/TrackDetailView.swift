// TrackDetailView.swift — Track metadata inspector
// Extracted from App/Views/MainView.swift to SharedUI for reuse.

import Core
import SwiftUI

/// Detailed track metadata view displayed in the detail pane.
public struct TrackDetailView: View {
    public let track: Track

    public init(track: Track) {
        self.track = track
    }

    public var body: some View {
        Form {
            Section("Track Info") {
                LabeledContent("Title", value: track.name)
                LabeledContent("Artist", value: track.artist)
                LabeledContent("Album", value: track.album)
            }

            Section("Metadata") {
                LabeledContent("Genre", value: track.genre ?? "Unknown")
                LabeledContent("Year", value: track.year.map(String.init) ?? "Unknown")
                LabeledContent("Track ID", value: track.id)
            }

            if let dateAdded = track.dateAdded {
                Section("Dates") {
                    LabeledContent("Date Added", value: dateAdded.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let kind = track.kind {
                Section("Status") {
                    LabeledContent("Type", value: kind.description)
                    LabeledContent("Can Edit", value: kind.canEditMetadata ? "Yes" : "No")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
