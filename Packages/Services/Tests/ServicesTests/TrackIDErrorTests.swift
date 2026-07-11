import Testing
@testable import Services

@Suite("Track ID scan errors")
struct TrackIDErrorTests {
    @Test("Rejects invalid wire responses", arguments: InvalidResponse.cases)
    func rejectsInvalidResponse(_ response: InvalidResponse) async {
        let scan = TrackIDScan(batchSize: 2, timeout: .seconds(1)) { _, _, _ in
            response.output
        }

        do {
            _ = try await scan.run()
            Issue.record("Expected invalid response to fail")
        } catch let error as AppleScriptBridgeError {
            #expect(response.error.matches(error))
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }
}

struct InvalidResponse: Sendable, CustomTestStringConvertible {
    let output: String?
    let error: ExpectedError

    var testDescription: String {
        output ?? "nil"
    }

    static let cases = [
        InvalidResponse(output: nil, error: .parse),
        InvalidResponse(output: "ERROR:Music failed", error: .execution),
        InvalidResponse(
            output: "ERROR:LIBRARY_DB_NOT_FOUND: Music library database not found at /Music/Library.musicdb",
            error: .path
        ),
        InvalidResponse(output: "INVALID", error: .parse),
        InvalidResponse(output: "BATCH:3:2:G1:A,B,C", error: .libraryChanged),
        InvalidResponse(output: "BATCH:2:2:G1:A", error: .parse),
        InvalidResponse(output: "BATCH:2:3::A,B", error: .parse),
    ]
}

enum ExpectedError: Sendable {
    case execution
    case libraryChanged
    case path
    case parse

    func matches(_ error: AppleScriptBridgeError) -> Bool {
        switch (self, error) {
        case (.execution, .executionFailed),
             (.libraryChanged, .libraryChanged),
             (.path, .invalidLibraryPath),
             (.parse, .parseError):
            true
        default:
            false
        }
    }
}
