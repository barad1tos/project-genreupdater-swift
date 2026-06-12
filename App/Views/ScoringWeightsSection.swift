// ScoringWeightsSection.swift - year scoring weight settings.

import Core
import SwiftUI

struct ScoringWeightsSection: View {
    let dependencies: AppDependencies

    var body: some View {
        Section("Match Scoring Weights") {
            ForEach(matchRows) { row in
                scoreStepper(row)
            }
        }

        Section("Release Scoring Weights") {
            ForEach(releaseRows) { row in
                scoreStepper(row)
            }
        }

        Section("Timeline and Source Weights") {
            ForEach(timelineRows) { row in
                scoreStepper(row)
            }
        }
    }

    private var matchRows: [ScoringWeightRow] {
        [
            ScoringWeightRow("Base score", \.baseScore, -100 ... 150),
            ScoringWeightRow("Artist exact match", \.artistExactMatchBonus, -100 ... 150),
            ScoringWeightRow("Artist substring", \.artistSubstringPenalty, -100 ... 150),
            ScoringWeightRow("Artist cross-script", \.artistCrossScriptPenalty, -100 ... 150),
            ScoringWeightRow("Artist mismatch", \.artistMismatchPenalty, -150 ... 50),
            ScoringWeightRow("Album exact match", \.albumExactMatchBonus, -100 ... 150),
            ScoringWeightRow("Perfect artist + album", \.perfectMatchBonus, -100 ... 150),
            ScoringWeightRow("Album substring", \.albumSubstringPenalty, -100 ... 150),
            ScoringWeightRow("Album unrelated", \.albumUnrelatedPenalty, -150 ... 50),
            ScoringWeightRow("Soundtrack compensation", \.soundtrackCompensationBonus, -100 ... 150),
        ]
    }

    private var releaseRows: [ScoringWeightRow] {
        [
            ScoringWeightRow("MusicBrainz release group", \.mbReleaseGroupMatchBonus, -100 ... 150),
            ScoringWeightRow("Album type", \.typeAlbumBonus, -100 ... 150),
            ScoringWeightRow("EP / single type", \.typeEPSinglePenalty, -150 ... 50),
            ScoringWeightRow("Compilation / live type", \.typeCompilationLivePenalty, -150 ... 50),
            ScoringWeightRow("Official status", \.statusOfficialBonus, -100 ... 150),
            ScoringWeightRow("Bootleg status", \.statusBootlegPenalty, -150 ... 50),
            ScoringWeightRow("Promo status", \.statusPromoPenalty, -150 ... 50),
            ScoringWeightRow("Reissue penalty", \.reissuePenalty, -150 ... 50),
        ]
    }

    private var timelineRows: [ScoringWeightRow] {
        [
            ScoringWeightRow("Before artist start", \.yearBeforeStartPenalty, -150 ... 50),
            ScoringWeightRow("After artist end", \.yearAfterEndPenalty, -150 ... 50),
            ScoringWeightRow("Near artist start", \.yearNearStartBonus, -100 ... 150),
            ScoringWeightRow("MusicBrainz source", \.sourceMBBonus, -100 ... 150),
            ScoringWeightRow("Discogs source", \.sourceDiscogsBonus, -100 ... 150),
            ScoringWeightRow("Apple Music source", \.sourceITunesBonus, -100 ... 150),
            ScoringWeightRow("Future year", \.futureYearPenalty, -150 ... 50),
            ScoringWeightRow("Current year", \.currentYearPenalty, -150 ... 50),
        ]
    }

    private func scoreStepper(_ row: ScoringWeightRow) -> some View {
        Stepper(value: scoreBinding(for: row), in: row.range) {
            LabeledContent(row.title, value: "\(scoreValue(for: row))")
        }
    }

    private func scoreBinding(for row: ScoringWeightRow) -> Binding<Int> {
        Binding(
            get: { scoreValue(for: row) },
            set: { newValue in
                dependencies.config.yearRetrieval.scoring[keyPath: row.keyPath] = newValue
                saveConfiguration(dependencies)
            }
        )
    }

    private func scoreValue(for row: ScoringWeightRow) -> Int {
        dependencies.config.yearRetrieval.scoring[keyPath: row.keyPath]
    }
}

private struct ScoringWeightRow: Identifiable {
    let id: String
    let title: String
    let keyPath: WritableKeyPath<ScoringConfig, Int>
    let range: ClosedRange<Int>

    init(
        _ title: String,
        _ keyPath: WritableKeyPath<ScoringConfig, Int>,
        _ range: ClosedRange<Int>
    ) {
        id = title
        self.title = title
        self.keyPath = keyPath
        self.range = range
    }
}
