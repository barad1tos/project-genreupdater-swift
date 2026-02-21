// PerformanceTests.swift — Performance regression tests for Services layer
//
// Uses XCTestCase with measure {} blocks (Swift Testing doesn't support these yet).
// These tests establish baselines for:
// - InputSanitizer script code validation throughput
// - InputSanitizer string sanitization throughput
// - GRDB cache lookup performance under load

import XCTest

@testable import Core
@testable import Services

final class ServicesPerformanceTests: XCTestCase {
    func testInputSanitizerValidation1000() {
        let inputs = (0 ..< 1000).map { "set property\($0) to value\($0)" }

        measure {
            for input in inputs {
                try? InputSanitizer.validateScriptCode(input)
            }
        }
    }

    func testInputSanitizerSanitize1000() {
        let inputs = (0 ..< 1000).map { "Track Name (\($0)) \"Remix\"" }

        measure {
            for input in inputs {
                _ = try? InputSanitizer.sanitizeString(input)
            }
        }
    }

    func testInputSanitizerEscapeStringValue1000() {
        let inputs = (0 ..< 1000).map {
            "Song Title (\($0)) feat. \"Artist\" [Deluxe]"
        }

        measure {
            for input in inputs {
                _ = InputSanitizer.escapeStringValue(input)
            }
        }
    }

    func testGRDBCacheLookup1000() async throws {
        let cache = try GRDBCacheService.createInMemory()
        try await cache.initialize()

        // Pre-populate 100 entries
        for index in 0 ..< 100 {
            await cache.storeAlbumYear(
                artist: "Artist\(index)",
                album: "Album\(index)",
                year: 2000 + index,
                confidence: 80
            )
        }

        // Measure lookup performance across 1000 iterations (cycling through 100 entries)
        let iterations = 1000
        measure {
            let expectation = self.expectation(description: "cacheLookup")
            Task {
                for index in 0 ..< iterations {
                    _ = await cache.getAlbumYear(
                        artist: "Artist\(index % 100)",
                        album: "Album\(index % 100)"
                    )
                }
                expectation.fulfill()
            }
            self.wait(for: [expectation], timeout: 30)
        }
    }
}
