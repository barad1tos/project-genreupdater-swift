import Foundation

/// Mock library data — internally consistent (coverage % ⇄ counts ⇄ health).
/// Swap this for your real services / LibraryDashboardSnapshot pipeline.
struct MockData {
    let snapshot = HealthSnapshot(
        health: 0.87, genre: 0.89, year: 0.92, consistency: 0.78,
        totalTracks: 42_318, missingGenre: 4_655, missingYear: 3_385,
        completeMetadata: 33_008, ready: 211, pendingVerification: 142,
        protectedFiles: 18, writeErrors: 0, recentlyAdded: 86,
        lastScan: "8m ago", nextRun: "21:00",
        source: "Apple Music · local files", library: "Music Library")

    let coverage: [CoverageBucket] = [
        .init(label: "Pop", ratio: 0.95, tone: .success),
        .init(label: "Electronic", ratio: 0.88, tone: .info),
        .init(label: "Rock", ratio: 0.82, tone: .purple),
        .init(label: "Hip-Hop", ratio: 0.71, tone: .warning),
        .init(label: "Unknown", ratio: 0.18, tone: .error),
    ]

    let issues: [Issue] = [
        .init(id: "pending", label: "Pending verification", count: "142", unit: "albums",
              tone: .purple, symbol: "eye", route: .update),
        .init(id: "protected", label: "Protected files", count: "18", tone: .neutral, symbol: "lock"),
        .init(id: "errors", label: "Write errors", count: "0", tone: .success, symbol: "checkmark.circle"),
    ]

    let metrics: [MetricTile] = [
        .init(label: "Missing Genres", value: "4,655", symbol: "tag.slash", tone: .warning, trendUp: false, delta: "128"),
        .init(label: "Missing Years", value: "3,385", symbol: "calendar.badge.exclamationmark", tone: .info, trendUp: false, delta: "74"),
        .init(label: "Complete Metadata", value: "33,008", symbol: "checkmark.seal", tone: .success),
    ]

    let activity: [ActivityItem] = [
        .init(title: "Library scan", detail: "42,318 tracks analyzed"),
        .init(title: "Updates staged", detail: "211 changes ready for review"),
        .init(title: "Dry-run preview", detail: "no tags written to Music"),
    ]

    let artists: [Artist] = [
        Artist(name: "Aphex Twin", genre: "Electronic", albums: [
            .init(name: "Selected Ambient Works 85-92", genre: "Electronic", year: 1992, tracks: 13, health: 1.0),
            .init(name: "Drukqs", genre: "Electronic", year: 2001, tracks: 30, health: 0.9),
            .init(name: "Syro", genre: nil, year: 2014, tracks: 12, health: 0.4),
        ]),
        Artist(name: "Bach, J.S.", genre: "Classical", albums: [
            .init(name: "Goldberg Variations", genre: "Classical", year: 1741, tracks: 32, health: 1.0),
            .init(name: "Cello Suites", genre: "Classical", year: nil, tracks: 36, health: 0.6),
        ]),
        Artist(name: "Boards of Canada", genre: "Electronic", albums: [
            .init(name: "Music Has the Right to Children", genre: nil, year: nil, tracks: 17, health: 0.2),
            .init(name: "Geogaddi", genre: "Electronic", year: 2002, tracks: 23, health: 0.95),
        ]),
        Artist(name: "Metallica", genre: "Metal", albums: [
            .init(name: "Master of Puppets", genre: "Metal", year: 1986, tracks: 8, health: 1.0),
            .init(name: "...And Justice for All", genre: "Metal", year: 1988, tracks: 9, health: 0.9),
            .init(name: "The Black Album", genre: "Metal", year: 1991, tracks: 12, health: 1.0),
        ]),
        Artist(name: "Miles Davis", genre: "Jazz", albums: [
            .init(name: "Kind of Blue", genre: "Jazz", year: 1959, tracks: 5, health: 1.0),
            .init(name: "Bitches Brew", genre: "Jazz", year: 1970, tracks: 6, health: 0.85),
        ]),
        Artist(name: "Radiohead", genre: "Alternative", albums: [
            .init(name: "OK Computer", genre: "Alternative", year: 1997, tracks: 12, health: 1.0),
            .init(name: "Kid A", genre: "Electronic", year: 2000, tracks: 10, health: 0.9),
            .init(name: "In Rainbows", genre: nil, year: nil, tracks: 10, health: 0.3),
        ]),
    ]

    let changes: [Change] = [
        .init(track: "Battery", artist: "Metallica", type: .genre, old: "Metal", new: "Thrash Metal", conf: 0.96),
        .init(track: "Idioteque", artist: "Radiohead", type: .year, old: nil, new: "2000", conf: 0.91),
        .init(track: "Windowlicker", artist: "Aphex Twin", type: .genre, old: nil, new: "IDM", conf: 0.74),
        .init(track: "So What", artist: "Miles Davis", type: .genre, old: "Jazz", new: "Modal Jazz", conf: 0.88),
        .init(track: "Roygbiv", artist: "Boards of Canada", type: .year, old: nil, new: "1998", conf: 0.69),
        .init(track: "Everything In Its Right Place", artist: "Radiohead", type: .genre, old: "Rock", new: "Art Rock", conf: 0.82),
        .init(track: "Aria", artist: "Bach, J.S.", type: .year, old: nil, new: "1741", conf: 0.63),
        .init(track: "Xtal", artist: "Aphex Twin", type: .genre, old: "Electronic", new: "Ambient", conf: 0.79),
        .init(track: "Pharaoh's Dance", artist: "Miles Davis", type: .genre, old: nil, new: "Jazz Fusion", conf: 0.48),
        .init(track: "Optimistic", artist: "Radiohead", type: .genre, old: "Rock", new: "Alternative", conf: 0.90),
        .init(track: "Damage, Inc.", artist: "Metallica", type: .genre, old: "Metal", new: "Thrash Metal", conf: 0.93),
    ]

    let dryRun = (changes: 211, tracks: 198, avgConfidence: 88, genre: 142, year: 69)

    let changeLog: [LogEntry] = [
        .init(time: "8m ago", type: .genre, track: "Master of Puppets (8 tracks)", artist: "Metallica", old: "Metal", new: "Thrash Metal", conf: 0.96),
        .init(time: "8m ago", type: .year, track: "Kid A", artist: "Radiohead", old: "—", new: "2000", conf: 0.91),
        .init(time: "12m ago", type: .genre, track: "Kind of Blue", artist: "Miles Davis", old: "Jazz", new: "Modal Jazz", conf: 0.88),
        .init(time: "Yesterday", type: .year, track: "Geogaddi", artist: "Boards of Canada", old: "—", new: "2002", conf: 0.77),
        .init(time: "Yesterday", type: .revert, track: "Syro", artist: "Aphex Twin", old: "2015", new: "2014", conf: 1.0),
        .init(time: "2d ago", type: .genre, track: "OK Computer", artist: "Radiohead", old: "Rock", new: "Art Rock", conf: 0.84),
    ]

    let reportStats = (processed: 211, genres: 142, years: 69)

    let genreDist: [ChartDatum] = [
        .init(label: "Thrash Metal", count: 38), .init(label: "IDM", count: 31),
        .init(label: "Art Rock", count: 24), .init(label: "Modal Jazz", count: 19),
        .init(label: "Ambient", count: 16), .init(label: "Jazz Fusion", count: 14),
    ]
    let overTime: [ChartDatum] = (["W1","W2","W3","W4","W5","W6","W7","W8","W9","W10","W11","W12"])
        .enumerated().map { ChartDatum(label: $0.element, count: [4,9,7,14,11,22,18,31,27,19,33,28][$0.offset]) }
    let yearDist: [ChartDatum] = [
        .init(label: "60s", count: 6), .init(label: "70s", count: 11), .init(label: "80s", count: 18),
        .init(label: "90s", count: 27), .init(label: "00s", count: 22), .init(label: "10s", count: 14), .init(label: "20s", count: 8),
    ]
}
