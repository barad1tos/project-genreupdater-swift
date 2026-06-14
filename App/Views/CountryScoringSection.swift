// CountryScoringSection.swift - country scoring settings.

import Core
import SwiftUI

struct CountryScoringSection: View {
    let dependencies: AppDependencies

    @State private var newMajorMarketCode = ""

    var body: some View {
        Section("Country Scoring") {
            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.scoring.countryArtistMatchBonus),
                in: -50 ... 50
            ) {
                LabeledContent(
                    "Artist country match bonus",
                    value: "\(dependencies.config.yearRetrieval.scoring.countryArtistMatchBonus)"
                )
            }

            Stepper(
                value: configBinding(dependencies, \.yearRetrieval.scoring.countryMajorMarketBonus),
                in: -50 ... 50
            ) {
                LabeledContent(
                    "Major market bonus",
                    value: "\(dependencies.config.yearRetrieval.scoring.countryMajorMarketBonus)"
                )
            }

            ForEach(dependencies.config.yearRetrieval.logic.majorMarketCodes, id: \.self) { code in
                Text(code.uppercased())
            }
            .onDelete { offsets in
                mutateConfiguration(dependencies) { configuration in
                    configuration.yearRetrieval.logic.majorMarketCodes.remove(atOffsets: offsets)
                }
            }

            HStack {
                TextField("Country code", text: $newMajorMarketCode)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addMajorMarketCode() }
                    .disabled(trimmedMajorMarketCode.isEmpty)
            }
        }
    }

    private var trimmedMajorMarketCode: String {
        newMajorMarketCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func addMajorMarketCode() {
        let code = trimmedMajorMarketCode
        guard !code.isEmpty else { return }
        guard !dependencies.config.yearRetrieval.logic.majorMarketCodes.contains(code) else {
            newMajorMarketCode = ""
            return
        }
        if mutateConfiguration(dependencies, { configuration in
            configuration.yearRetrieval.logic.majorMarketCodes.append(code)
        }) {
            newMajorMarketCode = ""
        }
    }
}
