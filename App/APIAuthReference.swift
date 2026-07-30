import Foundation

enum APIAuthReferenceResolver {
    static func resolve(
        _ reference: String,
        fallbackUserDefaultsKey: String? = nil
    ) -> String {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReference.isEmpty else { return "" }

        if let placeholderName = placeholderName(from: trimmedReference) {
            return value(forKey: placeholderName)
                ?? fallbackUserDefaultsKey.flatMap(value(forKey:))
                ?? ""
        }

        return value(forKey: trimmedReference) ?? trimmedReference
    }

    private static func placeholderName(from reference: String) -> String? {
        guard reference.hasPrefix("${"), reference.hasSuffix("}") else { return nil }
        return String(reference.dropFirst(2).dropLast())
    }

    private static func value(forKey key: String) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        return ProcessInfo.processInfo.environment[trimmedKey].flatMap(nonEmpty)
            ?? UserDefaults.standard.string(forKey: trimmedKey).flatMap(nonEmpty)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
