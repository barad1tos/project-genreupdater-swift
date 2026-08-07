// ExperienceLevel.swift — display-only user experience tiers (ADR 0002).

/// How much operational detail the UI shows. Display-only by contract:
/// neither level changes write authority, safety gates, scope, thresholds,
/// or processing behavior.
enum ExperienceLevel: String, CaseIterable, Identifiable {
    case casual
    case advanced

    /// The single source of the storage default (URLSessionConfiguration
    /// precedent for the keyword name).
    static let `default` = Self.advanced

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .casual: "Casual"
        case .advanced: "Advanced"
        }
    }
}
