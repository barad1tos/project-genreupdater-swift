import Foundation
import Testing
@testable import Core

@Suite("AppleScript year policy")
struct AppleScriptYearPolicyTests {
    @Test("Bundled year writers accept only the missing sentinel outside the valid range")
    func validatesYearPolicy() throws {
        for scriptName in ["update_property", "batch_update_tracks"] {
            #expect(try evaluateYearPolicy(scriptName, year: MusicAppYear.missingValue))
            #expect(try !evaluateYearPolicy(scriptName, year: -1))
            #expect(try !evaluateYearPolicy(scriptName, year: 1899))
            #expect(try evaluateYearPolicy(scriptName, year: 1999))
            #expect(try !evaluateYearPolicy(scriptName, year: 2029))
        }
    }

    @Test("Bundled year writers wire the policy into the write branch")
    func wiresPolicy() throws {
        for scriptName in ["update_property", "batch_update_tracks"] {
            let source = try scriptSource(scriptName)
            #expect(source.contains("if not my isYearAllowed(propValueInt, maxValidYear) then"))
        }
    }

    private func evaluateYearPolicy(_ scriptName: String, year: Int) throws -> Bool {
        let directory = try temporaryDirectory(for: scriptName)
        defer { removeDirectory(directory) }
        let sourceText = try scriptSource(scriptName)
        let handler = try yearPolicyHandler(in: sourceText, scriptName: scriptName)
        let policySource = directory.appendingPathComponent("\(scriptName)-year-policy.applescript")
        let compiled = directory.appendingPathComponent("\(scriptName).scpt")
        try "\(handler)\nreturn my isYearAllowed(\(year), 2028)\n"
            .write(to: policySource, atomically: true, encoding: .utf8)
        _ = try run(executableURL(named: "osacompile"), arguments: ["-o", compiled.path, policySource.path])
        let output = try run(executableURL(named: "osascript"), arguments: [compiled.path])
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func scriptSource(_ scriptName: String) throws -> String {
        try String(contentsOf: scriptURL(scriptName), encoding: .utf8)
    }

    private func scriptURL(_ scriptName: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Resources/Scripts")
            .appendingPathComponent("\(scriptName).applescript")
    }

    private func temporaryDirectory(for scriptName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleScriptYearPolicyTests-\(scriptName)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove AppleScript policy fixture: \(error)")
        }
    }

    private func yearPolicyHandler(in source: String, scriptName: String) throws -> String {
        guard let start = source.range(of: "on isYearAllowed"),
              let end = source.range(of: "end isYearAllowed", range: start.lowerBound ..< source.endIndex)
        else {
            throw ScriptPolicyError(
                executable: scriptName,
                detail: "missing isYearAllowed handler"
            )
        }
        return String(source[start.lowerBound ..< end.upperBound])
    }

    private func executableURL(named name: String) throws -> URL {
        let directories = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        for directory in directories {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ScriptPolicyError(executable: name, detail: "executable is not available on PATH")
    }

    private func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = standardError.fileHandleForReading.readDataToEndOfFile()
            throw ScriptPolicyError(
                executable: executable.lastPathComponent,
                detail: String(bytes: error, encoding: .utf8) ?? "Unreadable AppleScript error"
            )
        }
        return String(bytes: output, encoding: .utf8) ?? ""
    }

    private var repositoryRoot: URL {
        (0 ..< 5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
            url.deletingLastPathComponent()
        }
    }
}

private struct ScriptPolicyError: Error, CustomStringConvertible {
    let executable: String
    let detail: String

    var description: String {
        "\(executable) failed: \(detail)"
    }
}
