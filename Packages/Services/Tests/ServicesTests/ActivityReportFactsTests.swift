import Core
import Foundation
import Testing
@testable import Services

@Suite("Activity report facts")
struct ActivityReportFactsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        genre: String? = nil,
        year: Int? = nil,
        daysAgo: Double = 0,
        trackID: String = UUID().uuidString
    ) -> Core.ChangeLogEntry {
        Core.ChangeLogEntry(
            id: UUID(),
            timestamp: now.addingTimeInterval(-daysAgo * 24 * 3600),
            changeType: genre != nil ? .genreUpdate : .yearUpdate,
            trackID: trackID,
            artist: "Artist",
            newGenre: genre,
            newYear: year
        )
    }

    @Test("genre distribution keeps the top eight with an alphabetical tie-break")
    func genreTopEightTieBreak() {
        let entries = (0 ..< 9).map { index in
            entry(genre: "Genre-\(index)")
        }

        let facts = ActivityReportFacts.make(from: entries, now: now)

        #expect(facts.genreDistribution.count == 8)
        // Equal counts: alphabetical order decides, and Genre-8 drops.
        #expect(facts.genreDistribution.first?.label == "Genre-0")
        #expect(!facts.genreDistribution.contains { $0.label == "Genre-8" })
    }

    @Test("updates over time keep the trailing twelve days")
    func updatesOverTimeTrailingWindow() {
        let entries = (0 ..< 13).map { day in
            entry(genre: "Rock", daysAgo: Double(day))
        }

        let facts = ActivityReportFacts.make(from: entries, now: now)

        #expect(facts.updatesOverTime.count == 12)
        // The oldest (13th) day falls off; every kept bucket has one entry.
        #expect(facts.updatesOverTime.allSatisfy { $0.count == 1 })
    }

    @Test("the display log caps at the entry limit newest-first")
    func changeLogCapsAtLimit() {
        let entries = (0 ..< 150).map { index in
            entry(genre: "Rock", daysAgo: Double(index) / 100, trackID: "T\(index)")
        }

        let facts = ActivityReportFacts.make(from: entries, now: now)

        #expect(facts.changeLog.count == ActivityReportFacts.entryLimit)
        #expect(facts.stats.processed == ActivityReportFacts.entryLimit)
    }

    @Test("year decades bucket ascending")
    func yearDecadesAscending() {
        let entries = [
            entry(year: 1994),
            entry(year: 1997),
            entry(year: 2003),
        ]

        let facts = ActivityReportFacts.make(from: entries, now: now)

        #expect(facts.yearDistribution.map(\.label) == ["1990s", "2000s"])
        #expect(facts.yearDistribution.first?.count == 2)
    }
}
