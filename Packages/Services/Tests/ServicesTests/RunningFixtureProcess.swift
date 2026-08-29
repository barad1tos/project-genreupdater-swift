import Foundation

final class RunningFixtureProcess {
    let process: Process
    let outputDirectory: URL
    let outputURL: URL
    let errorURL: URL
    let standardOutput: FileHandle
    let standardError: FileHandle

    var isRunning: Bool {
        process.isRunning
    }

    init(
        process: Process,
        outputDirectory: URL,
        outputURL: URL,
        errorURL: URL,
        standardOutput: FileHandle,
        standardError: FileHandle
    ) {
        self.process = process
        self.outputDirectory = outputDirectory
        self.outputURL = outputURL
        self.errorURL = errorURL
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    func wait() throws -> Data {
        process.waitUntilExit()
        try standardOutput.close()
        try standardError.close()

        let output = try Data(contentsOf: outputURL)
        let errorOutput = try Data(contentsOf: errorURL)
        let outputText = String(data: output, encoding: .utf8) ?? "<non-UTF-8 output>"
        let errorText = String(data: errorOutput, encoding: .utf8) ?? "<non-UTF-8 output>"
        guard process.terminationStatus == 0 else {
            throw FixtureProcessError.failed(
                reason: process.terminationReason,
                status: process.terminationStatus,
                standardOutput: outputText,
                standardError: errorText
            )
        }
        return output
    }

    func cleanup() {
        try? standardOutput.close()
        try? standardError.close()
        try? FileManager.default.removeItem(at: outputDirectory)
    }
}
