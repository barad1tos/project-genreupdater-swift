import Testing
@testable import Services

@Suite("Track ID scan errors")
struct TrackIDErrorTests {
    @Test("Rejects invalid wire responses", arguments: InvalidResponse.cases)
    private func rejectsInvalidResponse(_ response: InvalidResponse) async {
        let scan = TrackIDScan(timeout: .seconds(1)) { _ in
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

private struct InvalidResponse: Sendable, CustomTestStringConvertible {
    let output: String?
    let error: ExpectedError

    var testDescription: String {
        output ?? "nil"
    }

    static let cases = [
        Self(output: nil, error: .parse),
        Self(output: "ERROR:Music failed", error: .execution),
        Self(
            output: "ERROR:LIBRARY_DB_NOT_FOUND: Music library database not found at /Music/Library.musicdb",
            error: .path
        ),
        Self(output: "INVALID", error: .parse),
        Self(output: "CENSUS:-1:G1:", error: .parse),
        Self(output: "CENSUS:2:G1:10", error: .parse),
        Self(output: "CENSUS:2::10,20", error: .parse),
    ]
}

private enum ExpectedError: Sendable {
    case execution
    case path
    case parse

    func matches(_ error: AppleScriptBridgeError) -> Bool {
        switch (self, error) {
        case (.execution, .executionFailed),
             (.path, .invalidLibraryPath),
             (.parse, .parseError):
            true
        default:
            false
        }
    }
}
