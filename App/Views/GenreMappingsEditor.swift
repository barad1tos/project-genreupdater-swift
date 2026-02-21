// GenreMappingsEditor.swift — Editable list of user-defined genre mappings.

import SwiftUI

// MARK: - Genre Mappings Editor

/// Editable list of user-defined genre mappings (source genre -> target genre).
///
/// Each row shows a source-to-target pair with a remove button.
/// A bottom row provides text fields and an add button for new mappings.
/// Designed to be embedded as a `Section` inside a `Form`.
struct GenreMappingsEditor: View {
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
                Text("No genre mappings configured")
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
            Text("Genre Mappings")
        } footer: {
            Text(
                "After genre determination, if the result matches a "
                    + "\"From\" value (case-insensitive), it is replaced "
                    + "with the \"To\" value."
            )
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
        HStack(spacing: 8) {
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
