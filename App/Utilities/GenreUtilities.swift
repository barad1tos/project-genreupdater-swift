// GenreUtilities.swift -- shared helpers for genre metadata checks.

import Foundation

enum GenreUtilities {
    static func hasPresentGenre(_ genre: String?) -> Bool {
        guard let genre else { return false }
        return !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
