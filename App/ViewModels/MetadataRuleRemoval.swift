import Core
import Services
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

    func removing(from configuration: AppConfiguration) -> AppConfiguration? {
        guard let remaining = removing(from: configuration[keyPath: rulesPath]) else { return nil }
        var updated = configuration
        updated[keyPath: rulesPath] = remaining
        return updated
    }

    private var rulesPath: WritableKeyPath<AppConfiguration, [String]> {
        switch group {
        case .editionMarkers: \.cleaning.editionMarkers
        case .albumSuffixes: \.cleaning.albumSuffixes
        case .specialAlbums: \.albumTypeDetection.specialPatterns
        case .compilations: \.albumTypeDetection.compilationPatterns
        case .reissues: \.albumTypeDetection.reissuePatterns
        case .soundtracks: \.albumTypeDetection.soundtrackPatterns
        case .variousArtists: \.albumTypeDetection.variousArtistsNames
        }
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

enum RuleRemovalOutcome {
    case applied
    case stale
    case unavailable
    case requiresAttention

    init(status: CommandResultStatus) {
        switch status {
        case .accepted:
            self = .applied
        case .rejectedStale:
            self = .stale
        case .requiresAttention:
            self = .requiresAttention
        case .temporaryUnavailable,
             .queued,
             .alreadyCovered,
             .noOp,
             .rejectedInvalid,
             .blockedByRecovery,
             .blockedByPermission,
             .navigated:
            self = .unavailable
        }
    }
}

struct MetadataRuleRemovalFlow {
    private static let staleMessage =
        "Metadata rules changed while confirmation was open. Review the current rules and try again."

    var pending: MetadataRuleRemoval?
    var failureMessage: String?

    mutating func request(
        _ removal: MetadataRuleRemoval,
        apply: (MetadataRuleRemoval) -> RuleRemovalOutcome
    ) {
        if removal.requiresConfirmation {
            pending = removal
        } else {
            finish(apply(removal))
        }
    }

    mutating func confirm(
        _ removal: MetadataRuleRemoval,
        apply: (MetadataRuleRemoval) -> RuleRemovalOutcome
    ) {
        guard pending == removal else { return }
        finish(apply(removal))
    }

    mutating func cancel() {
        pending = nil
    }

    mutating func dismissFailure() {
        failureMessage = nil
    }

    private mutating func finish(_ outcome: RuleRemovalOutcome) {
        pending = nil
        switch outcome {
        case .applied:
            failureMessage = nil
        case .stale:
            failureMessage = Self.staleMessage
        case .unavailable:
            failureMessage = "Metadata rules could not be saved. Nothing was changed. Try again."
        case .requiresAttention:
            failureMessage = "The stored settings revision is invalid. Restore or reset the configuration file."
        }
    }
}

private struct RuleRemovalDialog: ViewModifier {
    @Binding var flow: MetadataRuleRemovalFlow
    let apply: (MetadataRuleRemoval) -> RuleRemovalOutcome

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
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
            .alert(
                "Rule removal wasn’t applied",
                isPresented: Binding(
                    get: { flow.failureMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            flow.dismissFailure()
                        }
                    }
                )
            ) {
                Button("OK") { flow.dismissFailure() }
            } message: {
                Text(flow.failureMessage ?? "")
            }
    }
}

extension View {
    func confirmRuleRemoval(
        _ flow: Binding<MetadataRuleRemovalFlow>,
        apply: @escaping (MetadataRuleRemoval) -> RuleRemovalOutcome
    ) -> some View {
        modifier(RuleRemovalDialog(flow: flow, apply: apply))
    }
}
