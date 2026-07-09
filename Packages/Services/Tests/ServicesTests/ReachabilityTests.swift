import Foundation
import Testing
@testable import Services

@Suite("NetworkReachabilityMonitor — lifecycle")
struct ReachabilityTests {
    @Test("Initial state is connected")
    func initialStateIsConnected() async {
        let monitor = NetworkReachabilityMonitor()
        let connected = await monitor.isConnected
        #expect(connected)
    }

    @Test("Start and stop without crash")
    func startsAndStopsWithoutCrash() async {
        let monitor = NetworkReachabilityMonitor()
        await monitor.start()
        // Brief pause to let NWPathMonitor initialize
        try? await Task.sleep(for: .milliseconds(100))
        await monitor.stop()
    }
}
