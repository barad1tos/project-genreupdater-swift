import Foundation
import Testing
@testable import Core
@testable import Services

@Suite("Track ID bridge")
struct TrackIDBridgeTests {
    @Test("Builds the track ID script arguments")
    func buildsArguments() async throws {
        let bridge = AppleScriptBridge(
            installer: ScriptInstaller(
                scriptsDirectory: FileManager.default.temporaryDirectory,
                bundleScriptsDirectory: nil
            ),
            libraryPath: "  ${HOME}/Music/Library.musiclibrary  "
        )

        let arguments = try await bridge.trackIDArguments()

        #expect(arguments == ["${HOME}/Music/Library.musiclibrary"])
    }

    @Test("Rejects a missing library path before script execution")
    func rejectsMissingPath() async {
        let bridge = AppleScriptBridge(
            installer: ScriptInstaller(
                scriptsDirectory: FileManager.default.temporaryDirectory,
                bundleScriptsDirectory: nil
            )
        )

        do {
            _ = try await bridge.fetchTrackIDCensus()
            Issue.record("Expected a missing library path to fail")
        } catch let error as AppleScriptBridgeError {
            guard case .invalidLibraryPath = error else {
                Issue.record("Expected invalidLibraryPath, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppleScriptBridgeError, got \(error)")
        }
    }

    @Test("Wires one bulk census through the scan budget")
    func wiresScan() async throws {
        let bridge = AppleScriptBridge(
            installer: ScriptInstaller(
                scriptsDirectory: FileManager.default.temporaryDirectory,
                bundleScriptsDirectory: nil
            )
        )
        let log = ScanRequestLog()

        let census = try await bridge.scanTrackIDs(timeout: .seconds(1)) { remaining in
            await log.fetch(remaining: remaining)
        }

        let requests = await log.requests
        #expect(census.ids.map(\.rawValue) == ["10", "20", "30"])
        #expect(census.totalCount == 3)
        #expect(census.generation.rawValue == "G1")
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.remaining > .zero && $0.remaining <= .seconds(1) })
    }
}

private actor ScanRequestLog {
    struct Request: Sendable {
        let remaining: Duration
    }

    private(set) var requests: [Request] = []

    func fetch(remaining: Duration) -> String? {
        requests.append(Request(remaining: remaining))
        return "CENSUS:3:G1:10,20,30"
    }
}
