import Foundation
import Testing
@testable import Core

@Suite("Library sync configuration")
struct LibrarySyncConfigTests {
    @Test("Legacy configuration receives the library-sync retry policy")
    func decodesLegacyDefaults() throws {
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data("{}".utf8))

        #expect(configuration.librarySync.conflictRetries == 3)
        #expect(configuration.librarySync.conflictDelaySeconds == 0.1)
    }

    @Test("Persisted library-sync retry policy overrides defaults")
    func decodesPersistedPolicy() throws {
        let data = Data(#"{"librarySync":{"conflictRetries":2,"conflictDelaySeconds":0.25}}"#.utf8)

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)

        #expect(configuration.librarySync.conflictRetries == 2)
        #expect(configuration.librarySync.conflictDelaySeconds == 0.25)
    }

    @Test("Missing library-sync keys retain their defaults")
    func defaultsMissingPolicyKeys() throws {
        let retriesOnly = Data(#"{"librarySync":{"conflictRetries":2}}"#.utf8)
        let delayOnly = Data(#"{"librarySync":{"conflictDelaySeconds":0.25}}"#.utf8)

        let retriesConfiguration = try JSONDecoder().decode(AppConfiguration.self, from: retriesOnly)
        let delayConfiguration = try JSONDecoder().decode(AppConfiguration.self, from: delayOnly)

        #expect(retriesConfiguration.librarySync.conflictRetries == 2)
        #expect(retriesConfiguration.librarySync.conflictDelaySeconds == 0.1)
        #expect(delayConfiguration.librarySync.conflictRetries == 3)
        #expect(delayConfiguration.librarySync.conflictDelaySeconds == 0.25)
    }

    @Test("Negative library-sync retry policy is rejected")
    func rejectsNegativePolicy() throws {
        var configuration = AppConfiguration()
        configuration.librarySync.conflictRetries = -1
        configuration.librarySync.conflictDelaySeconds = -0.1

        do {
            try configuration.validate()
            Issue.record("Expected invalid library-sync retry policy to fail validation")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == [
                "librarySync.conflictDelaySeconds",
                "librarySync.conflictRetries",
            ])
        }
    }

    @Test("Library-sync delay overflow is rejected during validated decode")
    func rejectsDelayOverflow() throws {
        let data = Data(#"{"librarySync":{"conflictDelaySeconds":1e308}}"#.utf8)

        do {
            _ = try AppConfiguration.configurationDecoder().decode(AppConfiguration.self, from: data)
            Issue.record("Expected library-sync delay overflow to fail validation")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == ["librarySync.conflictDelaySeconds"])
            #expect(error.issues.first?.requirement == "must fit the millisecond duration capacity")
        }
    }

    @Test("Non-finite library-sync delay is rejected before runtime conversion")
    func rejectsNonFiniteDelay() throws {
        var configuration = AppConfiguration()
        configuration.librarySync.conflictDelaySeconds = .infinity

        do {
            try configuration.validate()
            Issue.record("Expected non-finite library-sync delay to fail validation")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == ["librarySync.conflictDelaySeconds"])
            #expect(error.issues.first?.requirement == "must be finite")
        }
    }
}
