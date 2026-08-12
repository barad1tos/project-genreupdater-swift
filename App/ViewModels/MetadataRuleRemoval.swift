import Core
import SwiftUI

struct MetadataRuleRemoval: Equatable, Identifiable {
    let group: MetadataRuleGroup
    let snapshot: [String]
    let offsets: IndexSet

    init?(group: MetadataRuleGroup, snapshot: [String], offsets: IndexSet) {
        guard !offsets.isEmpty, offsets.allSatisfy(snapshot.indices.contains) else { return nil }
        self.group = group
        self.snapshot = snapshot
        self.offsets = offsets
    }

    var values: [String] {
        offsets.map { snapshot[$0] }
    }

    var id: String {
        ([group.rawValue] + offsets.map(String.init)).joined(separator: "\u{1F}")
    }

    var requiresConfirmation: Bool {
        values.contains { MetadataRuleDefaults.contains($0, in: group) }
    }

    var actionTitle: String {
        values.count == 1 ? "Remove Rule" : "Remove Rules"
    }

    var message: String {
        let rules = values.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        return "Removing \(rules) changes future previews and runs. \(consequence)"
    }

    func removing(from current: [String]) -> [String]? {
        guard current == snapshot else { return nil }
        var remaining = current
        remaining.remove(atOffsets: offsets)
        return remaining
    }

    private var consequence: String {
        switch group {
        case .editionMarkers:
            "Matching edition text may remain in track and album names."
        case .albumSuffixes:
            "Matching album suffixes will no longer be proposed for removal."
        case .specialAlbums:
            "Matching albums may be handled as normal releases instead of special albums."
        case .compilations:
            "Matching albums may no longer receive compilation-specific handling."
        case .reissues:
            "Matching albums may no longer receive reissue-specific handling."
        case .soundtracks:
            "Matching albums may no longer use soundtrack-specific lookup and scoring."
        case .variousArtists:
            "Matching artist labels may no longer use the Various Artists search strategy."
        }
    }
}

struct MetadataRuleRemovalFlow {
    var pending: MetadataRuleRemoval?

    mutating func request(
        _ removal: MetadataRuleRemoval,
        apply: (MetadataRuleRemoval) -> Void
    ) {
        if removal.requiresConfirmation {
            pending = removal
        } else {
            apply(removal)
        }
    }

    mutating func confirm(
        _ removal: MetadataRuleRemoval,
        apply: (MetadataRuleRemoval) -> Void
    ) {
        guard pending == removal else { return }
        apply(removal)
        pending = nil
    }

    mutating func cancel() {
        pending = nil
    }
}

private struct RuleRemovalDialog: ViewModifier {
    @Binding var flow: MetadataRuleRemovalFlow
    let apply: (MetadataRuleRemoval) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove built-in metadata rule?",
            isPresented: Binding(
                get: { flow.pending != nil },
                set: { isPresented in
                    if !isPresented {
                        flow.cancel()
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: flow.pending
        ) { pending in
            Button(pending.actionTitle, role: .destructive) {
                flow.confirm(pending, apply: apply)
            }
            Button("Cancel", role: .cancel) {
                flow.cancel()
            }
        } message: { pending in
            Text(pending.message)
        }
    }
}

extension View {
    func confirmRuleRemoval(
        _ flow: Binding<MetadataRuleRemovalFlow>,
        apply: @escaping (MetadataRuleRemoval) -> Void
    ) -> some View {
        modifier(RuleRemovalDialog(flow: flow, apply: apply))
    }
}
