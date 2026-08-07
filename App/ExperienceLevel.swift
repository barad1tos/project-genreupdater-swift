// ExperienceLevel.swift — display-only user experience tiers (ADR 0002).

/// How much operational detail the UI shows. Display-only by contract:
/// neither level changes write authority, safety gates, scope, thresholds,
/// or processing behavior.
enum ExperienceLevel: String, CaseIterable, Identifiable {
    case casual
    case advanced

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
