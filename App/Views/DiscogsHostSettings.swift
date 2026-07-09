// DiscogsHostSettings.swift -- Discogs endpoint controls.

import Core
import SharedUI
import SwiftUI

extension APICacheTab {
    var discogsHostEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("API Host", text: $discogsHostInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { applyDiscogsHost() }

            HStack(spacing: Spacing.sm) {
                Button("Apply Host") { applyDiscogsHost() }
                    .disabled(isDiscogsHostApplyDisabled)
                Button("Reset to Default") { resetDiscogsHost() }
                    .disabled(isDiscogsHostResetDisabled)
            }

            HStack(spacing: 6) {
                Image(systemName: discogsHostStatusSymbolName)
                    .foregroundStyle(discogsHostStatusColor)
                Text(discogsHostStatusMessage)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.top, 4)
    }

    func loadDiscogsHostInput() {
        discogsHostInput = currentDiscogsBaseHost
    }

    private var currentDiscogsBaseHost: String {
        dependencies.config.yearRetrieval.apiAuth.discogsBaseHost
    }

    private var normalizedDiscogsHostInput: String? {
        APIAuthConfig.normalizedDiscogsBaseHost(discogsHostInput)
    }

    private var isDiscogsHostApplyDisabled: Bool {
        normalizedDiscogsHostInput == nil || normalizedDiscogsHostInput == currentDiscogsBaseHost
    }

    private var isDiscogsHostResetDisabled: Bool {
        discogsHostInput == APIAuthConfig.defaultDiscogsBaseHost
            && currentDiscogsBaseHost == APIAuthConfig.defaultDiscogsBaseHost
    }

    private var discogsHostStatusSymbolName: String {
        normalizedDiscogsHostInput == nil ? "exclamationmark.triangle.fill" : "network"
    }

    private var discogsHostStatusColor: Color {
        normalizedDiscogsHostInput == nil ? Ayu.warning : Ayu.success
    }

    private var discogsHostStatusMessage: String {
        guard !discogsHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Host is required."
        }
        guard let normalizedHost = normalizedDiscogsHostInput else {
            return "Use api.discogs.com or a Discogs subdomain, without scheme or path."
        }
        guard normalizedHost != currentDiscogsBaseHost else {
            return "Using https://\(normalizedHost)"
        }
        return "Ready to use https://\(normalizedHost)"
    }

    private func applyDiscogsHost() {
        guard let normalizedHost = normalizedDiscogsHostInput else {
            return
        }
        let previousHost = dependencies.config.yearRetrieval.apiAuth.discogsBaseHost
        if mutateConfiguration(dependencies, { configuration in
            configuration.yearRetrieval.apiAuth.discogsBaseHost = normalizedHost
        }) {
            discogsHostInput = normalizedHost
        } else {
            discogsHostInput = previousHost
        }
    }

    private func resetDiscogsHost() {
        discogsHostInput = APIAuthConfig.defaultDiscogsBaseHost
        applyDiscogsHost()
    }
}
