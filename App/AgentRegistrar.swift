import Foundation
import ServiceManagement

/// Registration surface for the bundled thin-waker agent (slice 14). A
/// protocol so settings logic pins against a stub — the real SMAppService
/// needs a login session and bundle identity no test runner has.
@MainActor
protocol AgentRegistrar {
    var isRegistered: Bool { get }
    /// The user revoked or has not yet granted Login Items consent; the
    /// only remedy is the System Settings pane.
    var needsApproval: Bool { get }
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
}

@MainActor
struct SMAppServiceRegistrar: AgentRegistrar {
    private let service = SMAppService.agent(plistName: "com.genreupdater.agent.plist")

    var isRegistered: Bool {
        service.status == .enabled
    }

    var needsApproval: Bool {
        service.status == .requiresApproval
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        // The async variant sends the non-Sendable SMAppService across
        // actors (a CI-only strict-concurrency error); the callback
        // variant runs the call synchronously on this actor.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension AppDependencies {
    /// Applies the explicit opt-in toggle (App Review 2.4.5(iii): never
    /// auto-register). Returns a user-facing failure line, nil on success.
    func setBackgroundWatcherEnabled(_ isEnabled: Bool) async -> String? {
        guard let agentRegistrar else {
            return "Background watcher is unavailable in this build"
        }
        // Enabling is Pro-gated; disabling must ALWAYS work, so a lapsed
        // subscription can still unregister the agent (the row stays
        // visible outside the feature gate for exactly this reason).
        if isEnabled, featureGate?.canAccess(.autoSync) != true {
            return "Background watching requires an active subscription"
        }
        do {
            if isEnabled {
                try agentRegistrar.register()
            } else {
                try await agentRegistrar.unregister()
            }
            return nil
        } catch {
            return "Background watcher change failed: \(error.localizedDescription)"
        }
    }
}
