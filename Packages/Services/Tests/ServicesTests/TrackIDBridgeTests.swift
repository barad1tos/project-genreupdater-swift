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

        let arguments = try await bridge.trackIDArguments(
            offset: 11,
            limit: 200
        )

        #expect(arguments == ["11", "200", "${HOME}/Music/Library.musiclibrary"])
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
            _ = try await bridge.fetchAllTrackIDs()
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

    @Test("Wires configured batches through one scan budget")
    func wiresScan() async throws {
        var configuration = AppleScriptConfig()
        configuration.batchProcessing.batchSize = 2
        let bridge = AppleScriptBridge(
            installer: ScriptInstaller(
                scriptsDirectory: FileManager.default.temporaryDirectory,
                bundleScriptsDirectory: nil
            ),
            config: configuration
        )
        let log = ScanRequestLog()

        let trackIDs = try await bridge.scanTrackIDs(timeout: .seconds(1)) { offset, limit, remaining in
            await log.fetch(offset: offset, limit: limit, remaining: remaining)
        }

        let requests = await log.requests
        #expect(trackIDs == ["A", "B", "C"])
        #expect(requests.map(\.offset) == [1, 3])
        #expect(requests.map(\.limit) == [2, 2])
        #expect(requests.allSatisfy { $0.remaining > .zero && $0.remaining <= .seconds(1) })
    }
}

private actor ScanRequestLog {
    struct Request: Sendable {
        let offset: Int
        let limit: Int
        let remaining: Duration
    }

    private(set) var requests: [Request] = []

    func fetch(offset: Int, limit: Int, remaining: Duration) -> String? {
        requests.append(Request(offset: offset, limit: limit, remaining: remaining))
        return offset == 1 ? "BATCH:2:3:G1:A,B" : "BATCH:3:3:G1:C"
    }
}
