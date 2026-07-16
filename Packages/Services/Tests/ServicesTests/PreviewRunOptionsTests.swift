import Core
import Foundation
import Services
import Testing

@Suite("PreviewRunOptions")
struct PreviewRunOptionsTests {
    @Test("preview options preserve selected genre and year flags")
    func preservesGenreAndYearFlags() {
        let options = PreviewRunOptions.make(
            configuration: AppConfiguration(),
            updateGenre: false,
            updateYear: true
        )

        #expect(options.updateGenre == false)
        #expect(options.updateYear == true)
    }

    @Test("preview options pin write and cleanup knobs off")
    func pinsWriteAndCleanupOff() {
        let options = PreviewRunOptions.make(
            configuration: AppConfiguration(),
            updateGenre: true,
            updateYear: true
        )

        #expect(options.repairExistingGenreMismatches == false)
        #expect(options.forceYearLookup == false)
        #expect(options.cleanTrackNames == false)
        #expect(options.cleanAlbumNames == false)
        #expect(options.autoAccept == false)
    }

    @Test("configuration snapshot never restores write authority")
    func staysReadOnly() {
        let snapshot = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(updateGenre: false, minConfidence: 73, autoAccept: true),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(snapshot.determinationOptions.updateGenre == false)
        #expect(snapshot.determinationOptions.minConfidence == 73)
        #expect(snapshot.determinationOptions.autoAccept == false)
    }

    @Test("Discogs availability changes preview fingerprints")
    func fingerprintsDiscogsAccess() {
        let disabled = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: false
        )
        let enabled = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            hasDiscogsAccess: true
        )

        #expect(disabled.fingerprint != enabled.fingerprint)
    }

    @Test("legacy snapshots preserve their stored fingerprint")
    func decodesLegacySnapshot() throws {
        let snapshot = FixPlanConfig.capture(
            configuration: AppConfiguration(),
            options: UpdateOptions(updateGenre: false, minConfidence: 73),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "appConfiguration")
        object.removeValue(forKey: "hasDiscogsAccess")
        object["fingerprint"] = "legacy-fingerprint"

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FixPlanConfig.self, from: legacyData)

        #expect(decoded.fingerprint == "legacy-fingerprint")
        #expect(decoded.minConfidence == 73)
        #expect(!decoded.hasDiscogsAccess)
    }

    @Test("snapshots without a Discogs reference digest use the configuration fallback")
    func decodesLegacyDigest() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "legacy-token"
        let snapshot = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(updateGenre: false, minConfidence: 73),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "discogsReferenceDigest")
        object.removeValue(forKey: "discogsCredentialRevision")
        let legacyConfiguration = try JSONEncoder().encode(configuration)
        object["appConfiguration"] = try JSONSerialization.jsonObject(with: legacyConfiguration)

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FixPlanConfig.self, from: legacyData)

        #expect(decoded.fingerprint == snapshot.fingerprint)
        #expect(decoded.minConfidence == 73)
    }

    @Test(
        "min confidence matches MainView clamp semantics",
        arguments: [
            (configured: 30.0, expected: 30),
            (configured: 57.0, expected: 57),
            (configured: 10.0, expected: 30),
            (configured: 250.0, expected: 100),
        ]
    )
    func clampsMinConfidence(configured: Double, expected: Int) {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = configured

        let options = PreviewRunOptions.make(
            configuration: configuration,
            updateGenre: true,
            updateYear: true
        )

        #expect(options.minConfidence == expected)
    }

    @Test("produced options have stable configuration fingerprints")
    func keepsStableFingerprints() {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.logic.minConfidenceForNewYear = 85
        let first = PreviewRunOptions.make(configuration: configuration, updateGenre: true, updateYear: false)
        let second = PreviewRunOptions.make(configuration: configuration, updateGenre: true, updateYear: false)
        let capturedAt = Date(timeIntervalSince1970: 100)

        let firstFingerprint = FixPlanConfig.capture(
            configuration: configuration,
            options: first,
            capturedAt: capturedAt
        ).fingerprint
        let secondFingerprint = FixPlanConfig.capture(
            configuration: configuration,
            options: second,
            capturedAt: capturedAt
        )
        .fingerprint

        #expect(firstFingerprint == secondFingerprint)
        #expect(firstFingerprint.count == 64)
    }

    @Test("determination settings change configuration fingerprints")
    func settingsShapeFingerprint() {
        var first = AppConfiguration()
        var second = first
        first.cleaning.genreMappings = ["Electronic": "Electronica"]
        second.cleaning.genreMappings = ["Electronic": "IDM"]
        let options = UpdateOptions()
        let capturedAt = Date(timeIntervalSince1970: 100)

        let firstFingerprint = FixPlanConfig.capture(
            configuration: first,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        let secondFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint

        #expect(firstFingerprint != secondFingerprint)
    }

    @Test("scheduling settings do not change fingerprints, cache and retries do")
    func distinguishesRuntimeInputs() {
        let first = AppConfiguration()
        var second = first
        second.runtime.dryRun.toggle()
        second.runtime.incrementalIntervalMinutes += 10
        let options = UpdateOptions()
        let capturedAt = Date(timeIntervalSince1970: 100)

        let firstFingerprint = FixPlanConfig.capture(
            configuration: first,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        let schedulingFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        #expect(schedulingFingerprint == firstFingerprint)

        second.runtime.cacheTTLSeconds += 60
        let cacheFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        #expect(cacheFingerprint != firstFingerprint)

        second = first
        second.runtime.maxGenericEntries += 1000
        let capacityFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        #expect(capacityFingerprint != firstFingerprint)

        second = first
        second.runtime.maxRetries += 1
        let retryFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        #expect(retryFingerprint != firstFingerprint)

        second = first
        second.runtime.retryDelaySeconds += 1
        let delayFingerprint = FixPlanConfig.capture(
            configuration: second,
            options: options,
            capturedAt: capturedAt
        ).fingerprint
        #expect(delayFingerprint != firstFingerprint)
    }

    @Test("runtime fingerprint projection reviews every runtime setting")
    func pinsRuntimeShape() throws {
        let data = try JSONEncoder().encode(RuntimeConfig())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == [
            "cacheTTLSeconds",
            "dryRun",
            "incrementalIntervalMinutes",
            "maxGenericEntries",
            "maxRetries",
            "retryDelaySeconds",
        ])
    }

    @Test("processing fingerprint projection reviews every processing setting")
    func pinsProcessingShape() throws {
        let data = try JSONEncoder().encode(ProcessingConfig())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == [
            "adaptiveDelay",
            "batchSize",
            "cacheTTLDays",
            "delayBetweenBatches",
            "futureYearThreshold",
            "incrementalIntervalMinutes",
            "minConfidenceToCache",
            "pendingVerificationIntervalDays",
            "prereleaseHandling",
            "prereleaseRecheckDays",
            "releaseYearRestoreThreshold",
            "skipPrerelease",
            "suspiciousAlbumMinLen",
            "suspiciousManyYears",
        ])
    }

    @Test("maintenance settings do not invalidate preview output")
    func ignoresMaintenance() {
        let first = AppConfiguration()
        var second = first
        second.caching.albumCacheSyncInterval += 60
        second.caching.cleanupErrorRetryDelay += 60
        second.caching.cleanupIntervalSeconds += 60
        second.caching.librarySnapshot.compress.toggle()
        second.caching.librarySnapshot.compressLevel += 1
        second.pendingVerification.autoVerifyDays += 1

        #expect(fingerprint(first) == fingerprint(second))
    }

    @Test("write settings do not invalidate preview output")
    func ignoresWriteSettings() {
        let first = AppConfiguration()
        var second = first
        second.processing.batchSize += 1
        second.processing.delayBetweenBatches += 1
        second.processing.adaptiveDelay.toggle()
        second.processing.releaseYearRestoreThreshold += 1
        second.applescript.timeouts.batchUpdate += .seconds(1)
        second.experimental.batchUpdatesEnabled.toggle()
        second.experimental.maxBatchSize += 1

        #expect(fingerprint(first) == fingerprint(second))
    }

    @Test("preview cache and processing settings remain fingerprinted")
    func tracksPreviewInputs() {
        let first = AppConfiguration()
        var second = first
        second.caching.negativeResultTTL += 60
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.processing.skipPrerelease.toggle()
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.processing.pendingVerificationIntervalDays += 1
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.genreUpdate.overrideExisting.toggle()
        #expect(fingerprint(first) != fingerprint(second))
    }

    @Test("AppleScript preview inputs remain fingerprinted")
    func tracksAppleScriptInputs() {
        let first = AppConfiguration()
        var second = first
        second.applescript.concurrency += 1
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.applescript.timeouts.fullLibraryFetch += .seconds(1)
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.applescript.rateLimit.requestsPerWindow += 1
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.applescript.retry.maxRetries += 1
        #expect(fingerprint(first) != fingerprint(second))

        second = first
        second.applescript.batchProcessing.idsBatchSize += 1
        #expect(fingerprint(first) != fingerprint(second))
    }

    @Test("encoded snapshots redact authentication values")
    func redactsAuthValues() throws {
        var configuration = AppConfiguration()
        configuration.yearRetrieval.apiAuth.discogsTokenReference = "literal-secret"
        configuration.yearRetrieval.apiAuth.contactEmailReference = "private-contact"
        let snapshot = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            discogsCredentialRevision: "revision-a"
        )

        let data = try JSONEncoder().encode(snapshot)
        let encoded = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(FixPlanConfig.self, from: data)

        #expect(!encoded.contains("literal-secret"))
        #expect(!encoded.contains("private-contact"))
        #expect(decoded.appConfiguration.yearRetrieval.apiAuth.discogsTokenReference.isEmpty)
        #expect(decoded.appConfiguration.yearRetrieval.apiAuth.contactEmailReference.isEmpty)
        #expect(decoded.fingerprint == snapshot.fingerprint)

        configuration.yearRetrieval.apiAuth.contactEmailReference = "different-contact"
        let contactChanged = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            discogsCredentialRevision: "revision-a"
        )
        #expect(contactChanged.fingerprint == snapshot.fingerprint)

        configuration.yearRetrieval.apiAuth.discogsTokenReference = "different-secret"
        let changed = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            discogsCredentialRevision: "revision-a"
        )
        #expect(changed.fingerprint != snapshot.fingerprint)

        configuration.yearRetrieval.apiAuth.discogsTokenReference = "literal-secret"
        let rotated = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100),
            discogsCredentialRevision: "revision-b"
        )
        #expect(rotated.fingerprint != snapshot.fingerprint)
    }

    @Test("populated configuration preserves its fingerprint through Codable")
    func configurationRoundTrips() throws {
        var configuration = AppConfiguration()
        configuration.cleaning.genreMappings = ["Electronic": "Electronica"]
        configuration.processing.batchSize = 17
        let snapshot = FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(minConfidence: 73),
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(FixPlanConfig.self, from: data)

        #expect(decoded.fingerprint == snapshot.fingerprint)
        #expect(decoded.appConfiguration.cleaning.genreMappings == ["Electronic": "Electronica"])
        #expect(decoded.appConfiguration.processing.batchSize == 17)
    }

    private func fingerprint(_ configuration: AppConfiguration) -> String {
        FixPlanConfig.capture(
            configuration: configuration,
            options: UpdateOptions(),
            capturedAt: Date(timeIntervalSince1970: 100)
        ).fingerprint
    }
}
