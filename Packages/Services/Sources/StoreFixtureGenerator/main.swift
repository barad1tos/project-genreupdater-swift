import Foundation
import Services

@main
struct StoreFixtureGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw GeneratorError.invalidArguments
        }
        try StoreFixtureWriter.writeV1(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }

    private enum GeneratorError: LocalizedError {
        case invalidArguments

        var errorDescription: String? {
            "Usage: StoreFixtureGenerator <store-path>"
        }
    }
}
