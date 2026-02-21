import OSLog
import Testing

@testable import Core

@Suite("AppLogger — logger factory and pre-built loggers")
struct AppLoggerTests {
    @Test("make(category:) returns a Logger without crashing")
    func makeCustomCategory() {
        let logger = AppLogger.make(category: "test")
        // Logger has no public properties to inspect; creation success is the test
        _ = logger
    }

    @Test(
        "Pre-built loggers are accessible",
        arguments: [
            ("general", AppLogger.general),
            ("appleScript", AppLogger.appleScript),
            ("api", AppLogger.api),
            ("cache", AppLogger.cache),
            ("genre", AppLogger.genre),
            ("year", AppLogger.year),
            ("processing", AppLogger.processing),
            ("subscription", AppLogger.subscription),
            ("sync", AppLogger.sync),
        ]
    )
    func preBuiltLoggers(_: String, logger: Logger) {
        // Accessing each static logger must not crash
        _ = logger
    }
}

@Suite("Duration.timeInterval — Foundation interop conversion")
struct DurationTimeIntervalTests {
    @Test("Whole seconds convert exactly")
    func wholeSeconds() {
        #expect(Duration.seconds(5).timeInterval == 5.0)
    }

    @Test("Fractional seconds convert accurately")
    func fractionalSeconds() {
        let result = Duration.milliseconds(1500).timeInterval
        #expect(abs(result - 1.5) < 1e-9)
    }

    @Test("Zero duration converts to 0.0")
    func zeroDuration() {
        #expect(Duration.zero.timeInterval == 0.0)
    }

    @Test("Large value (1 hour) converts exactly")
    func largeValue() {
        #expect(Duration.seconds(3600).timeInterval == 3600.0)
    }
}
