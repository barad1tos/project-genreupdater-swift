// MappingsEditor.swift - Editable list of user-defined metadata mappings.

import SharedUI
import SwiftUI

// MARK: - Mappings Editor

struct MappingsEditor: View {
    let title: String
    let emptyMessage: String
    let footerText: String
    @Binding var mappings: [String: String]
    @Binding var newSource: String
    @Binding var newTarget: String

    /// Sorted keys for stable display order.
    private var sortedKeys: [String] {
        mappings.keys.sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
    }

    var body: some View {
        Section {
            if sortedKeys.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(sortedKeys, id: \.self) { source in
                if let target = mappings[source] {
                    mappingRow(source: source, target: target)
                }
            }

            addMappingRow
        } header: {
            Text(title)
        } footer: {
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Subviews

    private func mappingRow(source: String, target: String) -> some View {
        HStack {
            Text(source)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(target)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive) {
                mappings.removeValue(forKey: source)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    private var addMappingRow: some View {
        HStack(spacing: Spacing.xs) {
            TextField("From", text: $newSource)
                .textFieldStyle(.roundedBorder)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField("To", text: $newTarget)
                .textFieldStyle(.roundedBorder)
            Button {
                addMapping()
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(isAddDisabled)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Logic

    private var isAddDisabled: Bool {
        let source = newSource.trimmingCharacters(in: .whitespaces)
        let target = newTarget.trimmingCharacters(in: .whitespaces)
        return source.isEmpty || target.isEmpty
    }

    private func addMapping() {
        let source = newSource.trimmingCharacters(in: .whitespaces)
        let target = newTarget.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, !target.isEmpty else { return }
        mappings[source] = target
        newSource = ""
        newTarget = ""
    }
}
