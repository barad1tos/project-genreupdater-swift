// AppStorageKey.swift -- shared UserDefaults keys used by app wiring and views.

enum AppStorageKey {
    /// Legacy storage location; kept only so the one-time migration into
    /// `AppConfiguration.processing.defaultUpdateBehavior` can find and
    /// clear it (`migrateDefaultUpdateBehaviorIfNeeded`).
    static let defaultUpdateBehavior = "defaultUpdateBehavior"
    /// Display-only experience tier (ADR 0002); deliberately UserDefaults,
    /// never AppConfiguration — it must stay out of the fingerprint.
    static let experienceLevel = "experienceLevel"
}
