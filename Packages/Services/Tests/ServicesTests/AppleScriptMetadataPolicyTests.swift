import Foundation
import Testing
@testable import Services

@Suite("AppleScript metadata normalization policy")
struct AppleScriptMetadataPolicyTests {
    @Test("Bulk snapshots route every date column through native timestamp serialization")
    func wiresBulkTimestampSerialization() throws {
        let source = try loadScriptSource("fetch_scope_metadata")

        #expect(source.contains("my join_timestamps(rawDateAddedValues, itemSeparator)"))
        #expect(source.contains("my join_timestamps(rawModifiedValues, itemSeparator)"))
        #expect(source.contains("my join_timestamps(rawReleaseDateValues, itemSeparator)"))
    }

    @Test("Bulk snapshots fail closed when the release-date column cannot be read")
    func surfacesReleaseDateColumnFailures() throws {
        let source = try loadScriptSource("fetch_scope_metadata")

        #expect(source.contains("set rawReleaseDateValues to release date of trackReference"))
        #expect(!source.contains("set rawReleaseDateValues to my missing_values(snapshotCount)"))
        #expect(!source.contains("on missing_values(valueCount)"))
    }

    @Test("Native timestamp columns decode without locale-dependent text")
    func decodesNativeTimestampColumn() throws {
        let timestamp = try evaluateTimestampColumn()
        let date = try #require(TrackWireCodec.parseDate(timestamp))

        #expect(timestamp.hasPrefix("unix:"))
        #expect(Calendar.current.component(.year, from: date) == 2024)
        #expect(TrackWireCodec.parseReleaseYear(timestamp) == 2024)
    }

    @Test("Text columns distinguish absent values from literal metadata")
    func preservesLiteralMissingValueText() throws {
        let output = try evaluateTextColumn()
        let values = try JSONDecoder().decode([String?].self, from: Data(output.utf8))

        #expect(values == [nil, "Missing Value", ""])
    }

    private func evaluateTimestampColumn() throws -> String {
        let fixture = """
        set fixtureDate to current date
        set year of fixtureDate to 2024
        set day of fixtureDate to 1
        set month of fixtureDate to February
        set day of fixtureDate to 3
        set hours of fixtureDate to 4
        set minutes of fixtureDate to 5
        set seconds of fixtureDate to 6
        return my join_timestamps({fixtureDate}, "|")
        """
        return try evaluateHandler(named: "join_timestamps", fixture: fixture)
    }

    private func evaluateTextColumn() throws -> String {
        try evaluateHandler(
            named: "json_text",
            fixture: "return my json_text({missing value, \"Missing Value\", \"\"})"
        )
    }

    private func evaluateHandler(named handlerName: String, fixture: String) throws -> String {
        let scriptName = "fetch_scope_metadata"
        let source = try loadScriptSource(scriptName)
        let handler = try extractHandler(named: handlerName, in: source, scriptName: scriptName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleScriptMetadataPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("\(scriptName)-metadata-policy.applescript")
        try "use framework \"Foundation\"\nuse scripting additions\n\n\(handler)\n\n\(fixture)\n"
            .write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try resolveTestExecutable(named: "osascript")
        process.arguments = [scriptURL.path]
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            throw MetadataPolicyError(
                scriptName: scriptName,
                detail: String(bytes: error, encoding: .utf8) ?? "Unreadable AppleScript error"
            )
        }
        return (String(bytes: output, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractHandler(named name: String, in source: String, scriptName: String) throws -> String {
        guard let start = source.range(of: "on \(name)"),
              let end = source.range(of: "end \(name)", range: start.lowerBound ..< source.endIndex)
        else {
            throw MetadataPolicyError(scriptName: scriptName, detail: "missing \(name) handler")
        }
        return String(source[start.lowerBound ..< end.upperBound])
    }

    private func loadScriptSource(_ scriptName: String) throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Resources/Scripts")
                .appendingPathComponent("\(scriptName).applescript"),
            encoding: .utf8
        )
    }

    private var repositoryRoot: URL {
        (0 ..< 5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
            url.deletingLastPathComponent()
        }
    }
}

private struct MetadataPolicyError: Error, CustomStringConvertible {
    let scriptName: String
    let detail: String

    var description: String {
        "\(scriptName) metadata policy failed: \(detail)"
    }
}
