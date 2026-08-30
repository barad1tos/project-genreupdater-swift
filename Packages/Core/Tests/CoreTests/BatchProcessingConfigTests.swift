import Foundation
import Testing
@testable import Core

@Suite("Batch processing configuration")
struct BatchProcessingConfigTests {
    @Test("Existing persisted configuration receives the bulk metadata default")
    func decodesBulkMetadataDefault() throws {
        let data = Data(#"{"idsBatchSize":17,"batchSize":1000}"#.utf8)

        let configuration = try JSONDecoder().decode(BatchProcessingConfig.self, from: data)

        #expect(configuration.bulkMetadataThreshold == 25)
    }

    @Test("Explicit bulk metadata threshold survives Codable round trip")
    func roundTripsBulkMetadataThreshold() throws {
        var configuration = BatchProcessingConfig()
        configuration.bulkMetadataThreshold = 42

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(BatchProcessingConfig.self, from: encoded)

        #expect(decoded.bulkMetadataThreshold == 42)
    }

    @Test("Encoded configuration omits obsolete metadata batch size")
    func omitsObsoleteMetadataBatchSize() throws {
        let encoded = try JSONEncoder().encode(BatchProcessingConfig())
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(object["idsBatchSize"] != nil)
        #expect(object["bulkMetadataThreshold"] != nil)
        #expect(object["batchSize"] == nil)
    }

    @Test("Bulk metadata threshold stays inside the supported range", arguments: [0, 1001])
    func rejectsUnsupportedBulkMetadataThreshold(_ threshold: Int) {
        var configuration = AppConfiguration()
        configuration.applescript.batchProcessing.bulkMetadataThreshold = threshold

        do {
            try configuration.validate()
            Issue.record("Expected bulk metadata threshold \(threshold) to be rejected")
        } catch let error as ConfigurationValidationError {
            #expect(error.issues.map(\.fieldPath) == ["applescript.batchProcessing.bulkMetadataThreshold"])
            #expect(error.issues.first?.receivedValue == String(threshold))
            #expect(error.issues.first?.requirement == "must be between 1 and 1000")
        } catch {
            Issue.record("Unexpected validation error: \(error)")
        }
    }
}
