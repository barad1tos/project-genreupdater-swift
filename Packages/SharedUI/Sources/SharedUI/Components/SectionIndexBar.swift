// SectionIndexBar.swift — Vertical alphabetical index bar with drag-to-scroll gesture.

import SwiftUI

// MARK: - SectionIndexBar

/// A vertical alphabetical index bar for fast list navigation.
///
/// Displays only letters that have content (smart mode) and supports drag-to-scroll
/// via `onLetterSelected`. Place this OUTSIDE the List as an overlay or in an HStack
/// to avoid coordinate space issues with scroll views.
///
/// Phase 6 usage:
/// ```
/// ScrollViewReader { proxy in
///     HStack(spacing: 0) {
///         List { ... sections with .id(letter) ... }
///         SectionIndexBar(letters: availableLetters) { letter in
///             withAnimation { proxy.scrollTo(letter, anchor: .top) }
///         }
///     }
/// }
/// ```
public struct SectionIndexBar: View {
    private let letters: [String]
    private let onLetterSelected: (String) -> Void

    @State private var activeLetter: String?
    @State private var isDragging = false

    private let letterHeight: CGFloat = 14
    private let letterSpacing: CGFloat = 2

    public init(
        letters: [String],
        onLetterSelected: @escaping (String) -> Void
    ) {
        self.letters = letters
        self.onLetterSelected = onLetterSelected
    }

    public var body: some View {
        VStack(spacing: letterSpacing) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(letter == activeLetter ? Ayu.accent : Ayu.fgSecondary)
                    .frame(width: 16, height: letterHeight)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .frame(width: 20)
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: Radius.xs)
                    .fill(Ayu.bgTertiary.opacity(0.5))
            }
        }
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    let stepHeight = letterHeight + letterSpacing
                    let adjustedY = value.location.y - Spacing.xxs
                    let index = Int(adjustedY / stepHeight)
                    let clampedIndex = min(max(index, 0), letters.count - 1)

                    guard !letters.isEmpty else { return }
                    let selected = letters[clampedIndex]

                    if selected != activeLetter {
                        activeLetter = selected
                        onLetterSelected(selected)
                    }
                }
                .onEnded { _ in
                    isDragging = false
                    activeLetter = nil
                }
        )
        .accessibilityLabel("Section index")
        .accessibilityHint("Drag to jump to a section")
    }
}

// MARK: - Preview

#Preview("SectionIndexBar") {
    // Full alphabet — the consumer filters to only letters with content at runtime
    let availableLetters = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
        "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
        "U", "V", "W", "X", "Y", "Z",
    ]

    HStack(spacing: 0) {
        // Placeholder list area
        List {
            ForEach(availableLetters, id: \.self) { letter in
                Section(letter) {
                    Text("Artists starting with \(letter)")
                        .foregroundStyle(Ayu.fgSecondary)
                }
            }
        }
        .frame(width: 300)

        SectionIndexBar(letters: availableLetters) { letter in
            print("Selected: \(letter)")
        }
    }
    .frame(height: 500)
}
