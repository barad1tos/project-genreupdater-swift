import Core
import Foundation

// MARK: - Proposed Change

/// A single proposed metadata change awaiting user review.
///
/// Built by `UpdateCoordinator` during dry-run or preview mode,
/// then filtered/toggled by `ChangePreviewPipeline` before write.
public struct ProposedChange: Sendable, Identifiable {
    public let id: UUID
    public let track: Track
    public let changeType: ChangeType
    public let oldValue: String?
    public let newValue: String?
    public let confidence: Int
    public let source: String
    public var isAccepted: Bool

    public init(
        id: UUID = UUID(),
        track: Track,
        changeType: ChangeType,
        oldValue: String?,
        newValue: String?,
        confidence: Int,
        source: String,
        isAccepted: Bool = true
    ) {
        self.id = id
        self.track = track
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.confidence = confidence
        self.source = source
        self.isAccepted = isAccepted
    }
}

// MARK: - Change Preview Pipeline

/// Aggregates and filters proposed changes before writing to Music.app.
///
/// Pure logic — no side effects, no actor isolation needed.
public struct ChangePreviewPipeline: Sendable {
    public init() {}

    /// Filter changes below a minimum confidence threshold.
    public func filter(
        changes: [ProposedChange],
        minConfidence: Int
    ) -> [ProposedChange] {
        changes.filter { $0.confidence >= minConfidence }
    }

    /// Group changes by "Artist — Album" for review UI.
    public func groupByArtistAlbum(
        _ changes: [ProposedChange]
    ) -> [(key: String, changes: [ProposedChange])] {
        let grouped = Dictionary(grouping: changes) { change in
            "\(change.track.artist) — \(change.track.album)"
        }
        return grouped
            .map { (key: $0.key, changes: $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// Accept all changes in the collection.
    public func acceptAll(_ changes: inout [ProposedChange]) {
        for index in changes.indices {
            changes[index].isAccepted = true
        }
    }

    /// Reject all changes in the collection.
    public func rejectAll(_ changes: inout [ProposedChange]) {
        for index in changes.indices {
            changes[index].isAccepted = false
        }
    }

    /// Toggle acceptance of a single change.
    public func toggle(_ change: inout ProposedChange) {
        change.isAccepted.toggle()
    }

    /// Export accepted changes to CSV format (Pro feature).
    public func exportCSV(_ changes: [ProposedChange]) -> String {
        var lines = ["Track ID,Artist,Album,Track,Change Type,Old Value,New Value,Confidence,Source"]
        let accepted = changes.filter(\.isAccepted)
        for change in accepted {
            let row = [
                escapeCSV(change.track.id),
                escapeCSV(change.track.artist),
                escapeCSV(change.track.album),
                escapeCSV(change.track.name),
                escapeCSV(change.changeType.rawValue),
                escapeCSV(change.oldValue ?? ""),
                escapeCSV(change.newValue ?? ""),
                String(change.confidence),
                escapeCSV(change.source),
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func escapeCSV(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"") || value.contains("\n")
        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
