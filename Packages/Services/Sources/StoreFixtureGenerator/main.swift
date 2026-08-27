import Foundation
import Services

@main
struct StoreFixtureGenerator {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 1 {
            try StoreFixtureWriter.writeV1(to: URL(fileURLWithPath: arguments[0]))
            return
        }
        guard arguments.count == 2 else {
            throw GeneratorError.invalidArguments
        }
        let storeURL = URL(fileURLWithPath: arguments[1])
        try await run(mode: arguments[0], storeURL: storeURL)
    }

    private static func run(mode: String, storeURL: URL) async throws {
        switch mode {
        case "migrate":
            try StoreFixtureVerifier.migrate(at: storeURL)
        case "v0":
            try StoreFixtureWriter.writeV0(to: storeURL)
        case "v3":
            try StoreFixtureWriter.writeV3(to: storeURL)
        case "verify-v3":
            let evidence = try StoreFixtureVerifier.verifyV3Migration(at: storeURL)
            try FileHandle.standardOutput.write(JSONEncoder().encode(evidence))
        case "v4":
            try StoreFixtureWriter.writeV4(to: storeURL)
        case "v2-recovery":
            try StoreFixtureWriter.writeRecoveryV2(to: storeURL)
        case "v2-membership", "verify-v2-membership":
            try runMembershipMode(mode, storeURL: storeURL)
        case "verify-v4":
            let evidence = try await StoreFixtureVerifier.verifyV4Migration(at: storeURL)
            try FileHandle.standardOutput.write(JSONEncoder().encode(evidence))
        case "diagnostic-failure":
            writeLargeDiagnostics()
            throw GeneratorError.diagnosticFailure
        default:
            throw GeneratorError.invalidArguments
        }
    }

    private static func runMembershipMode(_ mode: String, storeURL: URL) throws {
        switch mode {
        case "v2-membership":
            try StoreFixtureWriter.writeMembershipV2(to: storeURL)
        case "verify-v2-membership":
            let evidence = try StoreFixtureVerifier.verifyV2Migration(at: storeURL)
            try FileHandle.standardOutput.write(JSONEncoder().encode(evidence))
        default:
            throw GeneratorError.invalidArguments
        }
    }

    private static func writeLargeDiagnostics() {
        let output = Data(repeating: Character("o").asciiValue ?? 111, count: 70000)
            + Data("fixture-stdout-complete\n".utf8)
        let error = Data(repeating: Character("e").asciiValue ?? 101, count: 70000)
            + Data("fixture-stderr-complete\n".utf8)
        FileHandle.standardOutput.write(output)
        FileHandle.standardError.write(error)
    }

    private enum GeneratorError: LocalizedError {
        case invalidArguments
        case diagnosticFailure

        var errorDescription: String? {
            switch self {
            case .invalidArguments:
                "Usage: StoreFixtureGenerator "
                    + "[migrate|v0|v2-membership|verify-v2-membership|v2-recovery|v3|verify-v3|v4|verify-v4] "
                    + "<store-path>"
            case .diagnosticFailure:
                "Requested diagnostic failure"
            }
        }
    }
}
