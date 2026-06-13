import Foundation
import Network
import OSLog

// MARK: - Network Reachability Monitor

/// Monitors network connectivity using `NWPathMonitor`.
///
/// Provides a simple `isConnected` property for checking current status
/// and a `waitForConnection()` method for suspending until network returns.
/// Used by `APIOrchestrator` to skip API calls when offline.
public actor NetworkReachabilityMonitor {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var _isConnected: Bool = true
    private let log = Logger(subsystem: "com.genreupdater", category: "NetworkReachability")

    public init(initialIsConnected: Bool = true) {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.genreupdater.reachability")
        self._isConnected = initialIsConnected
    }

    public var isConnected: Bool {
        _isConnected
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.updateStatus(path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
        log.info("Network reachability monitoring started")
    }

    public func stop() {
        monitor.cancel()
        log.info("Network reachability monitoring stopped")
    }

    /// Suspend until network becomes available.
    public func waitForConnection() async {
        while !_isConnected {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func updateStatus(_ connected: Bool) {
        guard connected != _isConnected else { return }
        _isConnected = connected
        log.info("Network status: \(connected ? "connected" : "disconnected", privacy: .public)")
    }
}
