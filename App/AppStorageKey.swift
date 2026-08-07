// AppStorageKey.swift -- shared UserDefaults keys used by app wiring and views.

enum AppStorageKey {
    /// Legacy storage location; kept only so the one-time migration into
    /// `AppConfiguration.processing.defaultUpdateBehavior` can find and
    /// clear it (`migrateDefaultUpdateBehaviorIfNeeded`).
    static let defaultUpdateBehavior = "defaultUpdateBehavior"
}
