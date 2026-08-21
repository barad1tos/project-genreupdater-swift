import Core
import Foundation

extension APIOrchestrator {
    func aggregateResults(
        _ results: [SourceFetchResult],
        orderedSources: [APISource],
        at date: Date
    ) -> YearResult {
        var combinedScores: [Int: Int] = [:]

        for result in results.map(\.result) {
            for (year, score) in result.yearScores
                where yearValidator.acceptsCandidateYear(year, at: date) {
                combinedScores[year, default: 0] += score
            }
        }

        guard let bestScore = combinedScores.values.max() else {
            return YearResult()
        }

        let sourceRanks = Dictionary(uniqueKeysWithValues: orderedSources.enumerated().map { ($0.element, $0.offset) })
        let bestYear = combinedScores
            .filter { $0.value == bestScore }
            .keys
            .min { lhs, rhs in
                let lhsRank = Self.bestSourceRank(for: lhs, in: results, sourceRanks: sourceRanks)
                let rhsRank = Self.bestSourceRank(for: rhs, in: results, sourceRanks: sourceRanks)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs < rhs
            }

        guard let bestYear else {
            return YearResult()
        }

        let agreeingSourceCount = results.count(where: { $0.result.year == bestYear })
        return YearResult(
            year: bestYear,
            isDefinitive: agreeingSourceCount >= 2,
            confidence: min(bestScore, 100),
            yearScores: combinedScores
        )
    }

    private static func bestSourceRank(
        for year: Int,
        in results: [SourceFetchResult],
        sourceRanks: [APISource: Int]
    ) -> Int {
        results
            .filter { $0.result.year == year || $0.result.yearScores[year] != nil }
            .compactMap { sourceRanks[$0.source] }
            .min() ?? Int.max
    }
}
