import Core
import SwiftUI

struct ITunesSearchSection: View {
    let dependencies: AppDependencies

    var body: some View {
        Section("Apple Music / iTunes") {
            TextField(
                "Country",
                text: configBinding(dependencies, \.yearRetrieval.itunesSearch.countryCode)
            )
            .textFieldStyle(.roundedBorder)

            TextField(
                "Entity",
                text: configBinding(dependencies, \.yearRetrieval.itunesSearch.entity)
            )
            .textFieldStyle(.roundedBorder)

            Stepper(value: configBinding(dependencies, \.yearRetrieval.itunesSearch.limit), in: 1 ... 200) {
                LabeledContent(
                    "Search limit",
                    value: "\(dependencies.config.yearRetrieval.itunesSearch.clampedLimit)"
                )
            }

            Toggle(
                "Lookup fallback",
                isOn: configBinding(dependencies, \.yearRetrieval.itunesSearch.lookupFallbackEnabled)
            )
        }
    }
}
