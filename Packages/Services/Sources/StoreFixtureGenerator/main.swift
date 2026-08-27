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
        switch arguments[0] {
        case "v3":
            try StoreFixtureWriter.writeV3(to: storeURL)
        case "verify-v3":
            let evidence = try StoreFixtureVerifier.verifyV3Migration(at: storeURL)
            try FileHandle.standardOutput.write(JSONEncoder().encode(evidence))
        case "v4":
            try StoreFixtureWriter.writeV4(to: storeURL)
        case "verify-v4":
            let evidence = try await StoreFixtureVerifier.verifyV4Migration(at: storeURL)
            try FileHandle.standardOutput.write(JSONEncoder().encode(evidence))
        default:
            throw GeneratorError.invalidArguments
        }
    }

    private enum GeneratorError: LocalizedError {
        case invalidArguments

        var errorDescription: String? {
            "Usage: StoreFixtureGenerator [v3|verify-v3|v4|verify-v4] <store-path>"
        }
    }
}
