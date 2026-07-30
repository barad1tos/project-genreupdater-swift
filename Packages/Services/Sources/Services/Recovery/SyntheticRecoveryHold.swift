import Foundation

/// One stable identity for holds minted while the run-record store cannot be
/// read. Repeated failures re-admit the same hold instead of queueing
/// phantoms, and clearing it after the store recovers hands over to the real
/// record's hold with no synthetic residue.
public enum SyntheticRecoveryHold {
    public static let id = UUID(uuidString: "5E1FCA11-0000-4000-8000-000000000001") ?? UUID()
}
