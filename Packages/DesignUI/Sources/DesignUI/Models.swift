import SwiftUI

// MARK: - Navigation
enum Route: Hashable {
    case activity, browse, reports, update, settings
}

enum BrowseFilter: String, CaseIterable, Identifiable {
    case all, missingGenre, missingYear, conflicts
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .missingGenre: return "Missing genre"
        case .missingYear: return "Missing year"
        case .conflicts: return "Conflicts"
        }
    }
}

// MARK: - Snapshot (subset of LibraryDashboardSnapshot)
struct HealthSnapshot {
    var health: Double          // 0...1 composite
    var genre: Double
    var year: Double
    var consistency: Double
    var totalTracks: Int
    var missingGenre: Int
    var missingYear: Int
    var completeMetadata: Int
    var ready: Int              // staged updates
    var pendingVerification: Int
    var protectedFiles: Int
    var writeErrors: Int
    var recentlyAdded: Int
    var lastScan: String
    var nextRun: String
    var source: String
    var library: String
}

// MARK: - Activity models
struct CoverageBucket: Identifiable {
    let id = UUID(); let label: String; let ratio: Double; let tone: Tone
}

struct Issue: Identifiable {
    let id: String
    let label: String
    let count: String
    var unit: String? = nil
    let tone: Tone
    let symbol: String
    var trendDown: String? = nil
    var route: Route? = nil
}

struct MetricTile: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let symbol: String
    let tone: Tone
    var trendUp: Bool? = nil
    var delta: String? = nil
}

struct ActivityItem: Identifiable {
    let id = UUID(); let title: String; let detail: String
}

// MARK: - Library / changes
struct Album: Identifiable {
    let id = UUID()
    let name: String
    let genre: String?
    let year: Int?
    let tracks: Int
    let health: Double
}

struct Artist: Identifiable {
    let id = UUID()
    let name: String
    let genre: String
    let albums: [Album]
    var totalTracks: Int { albums.reduce(0) { $0 + $1.tracks } }
    var indexLetter: String {
        let n = name.hasPrefix("The ") ? String(name.dropFirst(4)) : name
        let c = n.first.map(String.init)?.uppercased() ?? "#"
        return c.range(of: "[A-Z]", options: .regularExpression) != nil ? c : "#"
    }
}

enum ChangeType: String {
    case genre, year, revert
    var symbol: String {
        switch self { case .genre: return "tag"; case .year: return "calendar"; case .revert: return "arrow.uturn.backward" }
    }
    var tone: Tone {
        switch self { case .genre: return .purple; case .year: return .info; case .revert: return .error }
    }
}

struct Change: Identifiable {
    let id = UUID()
    let track: String
    let artist: String
    let type: ChangeType
    let old: String?
    let new: String
    let conf: Double
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time: String
    let type: ChangeType
    let track: String
    let artist: String
    let old: String
    let new: String
    let conf: Double
}

struct ChartDatum: Identifiable {
    let id = UUID(); let label: String; let count: Int
}

func confidenceTone(_ c: Double) -> Tone { c >= 0.8 ? .success : c >= 0.5 ? .warning : .error }
func healthTone(_ r: Double) -> Tone { r >= 0.9 ? .success : r >= 0.6 ? .warning : .error }
