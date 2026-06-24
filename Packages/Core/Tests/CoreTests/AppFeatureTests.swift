import Testing
@testable import Core

@Suite("AppFeature — tier requirements per PRD Section 7")
struct AppFeatureTests {
    @Test("Free features require .free tier")
    func freeFeatures() {
        let freeFeatures: [AppFeature] = [
            .genreUpdate, .yearUpdate, .preview, .undo,
            .libraryBrowsing, .basicCaching, .reportsLog,
        ]
        for feature in freeFeatures {
            #expect(feature.minimumTier == .free, "\(feature) should be free")
        }
    }

    @Test("WeekPass features require .weekPass tier")
    func weekPassFeatures() {
        let weekPassFeatures: [AppFeature] = [
            .batchProcessing, .reportsCharts,
            .artistAlbumCleaning, .advancedCache,
        ]
        for feature in weekPassFeatures {
            #expect(feature.minimumTier == .weekPass, "\(feature) should require weekPass")
        }
    }

    @Test("Pro features require .pro tier")
    func proFeatures() {
        #expect(AppFeature.autoSync.minimumTier == .pro)
    }

    @Test("Total feature count is 12")
    func featureCount() {
        #expect(AppFeature.allCases.count == 12)
    }

    @Test("Free tier count is 7, WeekPass 4, Pro 1")
    func tierDistribution() {
        let grouped = Dictionary(grouping: AppFeature.allCases, by: \.minimumTier)
        #expect(grouped[.free]?.count == 7)
        #expect(grouped[.weekPass]?.count == 4)
        #expect(grouped[.pro]?.count == 1)
    }
}
