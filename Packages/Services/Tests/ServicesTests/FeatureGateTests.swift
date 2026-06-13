import Core
import Testing
@testable import Services

// MARK: - Access Control

@Suite("FeatureGate — feature access per tier")
@MainActor
struct FeatureGateAccessTests {
    @Test("Free tier can access all free features")
    func freeAccessesFreeFeatures() {
        let gate = FeatureGate(fixedTier: .free)
        let freeFeatures: [AppFeature] = [
            .genreUpdate, .yearUpdate, .preview, .undo,
            .libraryBrowsing, .basicCaching, .reportsLog,
        ]
        for feature in freeFeatures {
            #expect(gate.canAccess(feature), "Free should access \(feature)")
        }
    }

    @Test("Free tier cannot access weekPass or pro features")
    func freeDeniedPaidFeatures() {
        let gate = FeatureGate(fixedTier: .free)
        let paidFeatures: [AppFeature] = [
            .batchProcessing, .reportsCharts, .csvExport,
            .artistAlbumCleaning, .advancedCache, .autoSync,
        ]
        for feature in paidFeatures {
            #expect(!gate.canAccess(feature), "Free should NOT access \(feature)")
        }
    }

    @Test("WeekPass tier can access free + weekPass features")
    func weekPassAccessesOwnFeatures() {
        let gate = FeatureGate(fixedTier: .weekPass)
        let accessible: [AppFeature] = [
            .genreUpdate, .yearUpdate, .preview, .undo,
            .libraryBrowsing, .basicCaching, .reportsLog,
            .batchProcessing, .reportsCharts, .csvExport,
            .artistAlbumCleaning, .advancedCache,
        ]
        for feature in accessible {
            #expect(gate.canAccess(feature), "WeekPass should access \(feature)")
        }
    }

    @Test("WeekPass tier cannot access pro features")
    func weekPassDeniedPro() {
        let gate = FeatureGate(fixedTier: .weekPass)
        #expect(!gate.canAccess(.autoSync))
    }

    @Test("Pro tier can access all 13 features")
    func proAccessesAll() {
        let gate = FeatureGate(fixedTier: .pro)
        for feature in AppFeature.allCases {
            #expect(gate.canAccess(feature), "Pro should access \(feature)")
        }
    }
}

// MARK: - Require (throws)

@Suite("FeatureGate — require throws on insufficient tier")
@MainActor
struct FeatureGateRequireTests {
    @Test("require succeeds for accessible feature")
    func requireSucceeds() throws {
        let gate = FeatureGate(fixedTier: .pro)
        try gate.require(.autoSync)
    }

    @Test("require throws for inaccessible feature")
    func requireThrows() {
        let gate = FeatureGate(fixedTier: .free)
        #expect(throws: FeatureGateError.self) {
            try gate.require(.batchProcessing)
        }
    }

    @Test("require error contains correct tier info")
    func requireErrorDetails() {
        let gate = FeatureGate(fixedTier: .free)
        do {
            try gate.require(.autoSync)
            Issue.record("Should have thrown")
        } catch let error as FeatureGateError {
            if case let .featureRequiresTier(feature, required, current) = error {
                #expect(feature == .autoSync)
                #expect(required == .pro)
                #expect(current == .free)
            } else {
                Issue.record("Wrong error case")
            }
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

// MARK: - Track Capacity

@Suite("FeatureGate — free tier track limits")
@MainActor
struct FeatureGateTrackLimitTests {
    @Test("Paid tiers have unlimited track capacity")
    func paidUnlimited() {
        let weekGate = FeatureGate(fixedTier: .weekPass)
        let proGate = FeatureGate(fixedTier: .pro)
        #expect(weekGate.canProcessTracks(count: 10000))
        #expect(proGate.canProcessTracks(count: 10000))
    }

    @Test("Free tier allows tracks within limit")
    func freeWithinLimit() {
        let gate = FeatureGate(fixedTier: .free, freeTracksUsed: 400)
        #expect(gate.canProcessTracks(count: 100))
        #expect(gate.canProcessTracks(count: 1))
    }

    @Test("Free tier blocks tracks exceeding limit")
    func freeExceedsLimit() {
        let gate = FeatureGate(fixedTier: .free, freeTracksUsed: 400)
        #expect(!gate.canProcessTracks(count: 101))
    }

    @Test("Free tier at exactly 500 allows 0 more")
    func freeAtLimit() {
        let gate = FeatureGate(fixedTier: .free, freeTracksUsed: 500)
        #expect(gate.canProcessTracks(count: 0))
        #expect(!gate.canProcessTracks(count: 1))
    }

    @Test("requireTrackCapacity throws when exceeded")
    func requireThrows() {
        let gate = FeatureGate(fixedTier: .free, freeTracksUsed: 499)
        #expect(throws: FeatureGateError.self) {
            try gate.requireTrackCapacity(count: 2)
        }
    }

    @Test("Track limit error describes remaining capacity")
    func trackLimitErrorDescription() {
        let error = FeatureGateError.freeTrackLimitReached(limit: 500, used: 499)

        #expect(error.localizedDescription.contains("Free tier track limit reached"))
        #expect(error.localizedDescription.contains("1 track remaining"))
    }

    @Test("Track capacity counts unique track IDs")
    func trackCapacityCountsUniqueTrackIDs() throws {
        let gate = FeatureGate(fixedTier: .free, freeTracksUsed: 498)
        let tracks = [
            Track(id: "T1", name: "Song 1", artist: "Artist", album: "Album"),
            Track(id: "T1", name: "Song 1", artist: "Artist", album: "Album"),
            Track(id: "T2", name: "Song 2", artist: "Artist", album: "Album"),
        ]

        let requiredCapacity = try gate.requireTrackCapacity(for: tracks)

        #expect(requiredCapacity == 2)
    }

    @Test("Free track limit constant is 500")
    func limitConstant() {
        #expect(FeatureGate.freeTrackLimit == 500)
    }
}

// MARK: - Accessible / Locked Features

@Suite("FeatureGate — feature listing")
@MainActor
struct FeatureGateListingTests {
    @Test("Free tier: 7 accessible, 6 locked")
    func freeListings() {
        let gate = FeatureGate(fixedTier: .free)
        #expect(gate.accessibleFeatures().count == 7)
        #expect(gate.lockedFeatures().count == 6)
    }

    @Test("WeekPass tier: 12 accessible, 1 locked")
    func weekPassListings() {
        let gate = FeatureGate(fixedTier: .weekPass)
        #expect(gate.accessibleFeatures().count == 12)
        #expect(gate.lockedFeatures().count == 1)
    }

    @Test("Pro tier: 13 accessible, 0 locked")
    func proListings() {
        let gate = FeatureGate(fixedTier: .pro)
        #expect(gate.accessibleFeatures().count == 13)
        #expect(gate.lockedFeatures().isEmpty)
    }
}
