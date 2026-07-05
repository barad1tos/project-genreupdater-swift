import Foundation

/// Mock library data — internally consistent (coverage % ⇄ counts ⇄ health).
/// Swap this for your real services / LibraryDashboardSnapshot pipeline.
struct MockData {
    let snapshot = HealthSnapshot(
        health: 0.87, genre: 0.89, year: 0.92, consistency: 0.78,
        totalTracks: 42318, missingGenre: 4655, missingYear: 3385,
        completeMetadata: 33008, ready: 211, pendingVerification: 142,
        protectedFiles: 18, writeErrors: 0, recentlyAdded: 86,
        lastScan: "8m ago", nextRun: "21:00",
        source: "Apple Music · local files", library: "Music Library"
    )

    let pipelineActivity = PipelineActivitySnapshot.previewDefault(
        deltaCount: 211,
        interventionCount: 142,
        protectedCount: 18,
        failedWriteCount: 0
    )

    let pendingVerification = PendingVerificationSnapshot(
        totalAlbums: 142,
        dueAlbums: 12,
        skippedByInterval: 5,
        problematicAlbums: 3,
        verifiedAlbums: 7
    )

    let coverage: [CoverageBucket] = [
        .init(id: "genre-pop", label: "Pop", ratio: 0.95, tone: .success),
        .init(id: "genre-electronic", label: "Electronic", ratio: 0.88, tone: .info),
        .init(id: "genre-rock", label: "Rock", ratio: 0.82, tone: .purple),
        .init(id: "genre-hip-hop", label: "Hip-Hop", ratio: 0.71, tone: .warning),
        .init(id: "genre-unknown", label: "Unknown", ratio: 0.18, tone: .error),
    ]

    let issues: [Issue] = [
        .init(
            id: "pending",
            label: "Pending verification",
            count: "142",
            unit: "albums",
            tone: .purple,
            symbol: "eye",
            route: .update
        ),
        .init(id: "protected", label: "Protected files", count: "18", tone: .neutral, symbol: "lock"),
        .init(id: "errors", label: "Write errors", count: "0", tone: .success, symbol: "checkmark.circle"),
    ]

    let metrics: [MetricTile] = [
        .init(
            id: "missing-genres",
            label: "Missing Genres",
            value: "4,655",
            symbol: "tag.slash",
            tone: .warning,
            trendUp: false,
            delta: "128"
        ),
        .init(
            id: "missing-years",
            label: "Missing Years",
            value: "3,385",
            symbol: "calendar.badge.exclamationmark",
            tone: .info,
            trendUp: false,
            delta: "74"
        ),
        .init(
            id: "complete-metadata",
            label: "Complete Metadata",
            value: "33,008",
            symbol: "checkmark.seal",
            tone: .success
        ),
    ]

    let activity: [ActivityItem] = [
        .init(id: "library-scan", title: "Library scan", detail: "42,318 tracks analyzed"),
        .init(id: "updates-staged", title: "Updates staged", detail: "211 changes ready for review"),
        .init(id: "dry-run-preview", title: "Dry-run preview", detail: "no tags written to Music"),
    ]

    let artists: [Artist] = [
        Artist(id: "artist-aphex-twin", name: "Aphex Twin", genre: "Electronic", albums: [
            .init(
                id: "album-aphex-selected-ambient",
                name: "Selected Ambient Works 85-92",
                genre: "Electronic",
                year: 1992,
                tracks: 13,
                health: 1.0
            ),
            .init(id: "album-aphex-drukqs", name: "Drukqs", genre: "Electronic", year: 2001, tracks: 30, health: 0.9),
            .init(id: "album-aphex-syro", name: "Syro", genre: nil, year: 2014, tracks: 12, health: 0.4),
        ]),
        Artist(id: "artist-bach", name: "Bach, J.S.", genre: "Classical", albums: [
            .init(
                id: "album-bach-goldberg",
                name: "Goldberg Variations",
                genre: "Classical",
                year: 1741,
                tracks: 32,
                health: 1.0
            ),
            .init(
                id: "album-bach-cello-suites",
                name: "Cello Suites",
                genre: "Classical",
                year: nil,
                tracks: 36,
                health: 0.6
            ),
        ]),
        Artist(id: "artist-boards-of-canada", name: "Boards of Canada", genre: "Electronic", albums: [
            .init(
                id: "album-boc-music-has-right",
                name: "Music Has the Right to Children",
                genre: nil,
                year: nil,
                tracks: 17,
                health: 0.2
            ),
            .init(
                id: "album-boc-geogaddi",
                name: "Geogaddi",
                genre: "Electronic",
                year: 2002,
                tracks: 23,
                health: 0.95
            ),
        ]),
        Artist(id: "artist-metallica", name: "Metallica", genre: "Metal", albums: [
            .init(
                id: "album-metallica-master",
                name: "Master of Puppets",
                genre: "Metal",
                year: 1986,
                tracks: 8,
                health: 1.0
            ),
            .init(
                id: "album-metallica-justice",
                name: "...And Justice for All",
                genre: "Metal",
                year: 1988,
                tracks: 9,
                health: 0.9
            ),
            .init(
                id: "album-metallica-black",
                name: "The Black Album",
                genre: "Metal",
                year: 1991,
                tracks: 12,
                health: 1.0
            ),
        ]),
        Artist(id: "artist-miles-davis", name: "Miles Davis", genre: "Jazz", albums: [
            .init(
                id: "album-miles-kind-of-blue",
                name: "Kind of Blue",
                genre: "Jazz",
                year: 1959,
                tracks: 5,
                health: 1.0
            ),
            .init(
                id: "album-miles-bitches-brew",
                name: "Bitches Brew",
                genre: "Jazz",
                year: 1970,
                tracks: 6,
                health: 0.85
            ),
        ]),
        Artist(id: "artist-radiohead", name: "Radiohead", genre: "Alternative", albums: [
            .init(
                id: "album-radiohead-ok-computer",
                name: "OK Computer",
                genre: "Alternative",
                year: 1997,
                tracks: 12,
                health: 1.0
            ),
            .init(id: "album-radiohead-kid-a", name: "Kid A", genre: "Electronic", year: 2000, tracks: 10, health: 0.9),
            .init(
                id: "album-radiohead-in-rainbows",
                name: "In Rainbows",
                genre: nil,
                year: nil,
                tracks: 10,
                health: 0.3
            ),
        ]),
    ]

    let changes: [Change] = [
        .init(
            id: "change-battery-genre",
            track: "Battery",
            artist: "Metallica",
            type: .genre,
            old: "Metal",
            new: "Thrash Metal",
            conf: 0.96
        ),
        .init(
            id: "change-idioteque-year",
            track: "Idioteque",
            artist: "Radiohead",
            type: .year,
            old: nil,
            new: "2000",
            conf: 0.91
        ),
        .init(
            id: "change-windowlicker-genre",
            track: "Windowlicker",
            artist: "Aphex Twin",
            type: .genre,
            old: nil,
            new: "IDM",
            conf: 0.74
        ),
        .init(
            id: "change-so-what-genre",
            track: "So What",
            artist: "Miles Davis",
            type: .genre,
            old: "Jazz",
            new: "Modal Jazz",
            conf: 0.88
        ),
        .init(
            id: "change-roygbiv-year",
            track: "Roygbiv",
            artist: "Boards of Canada",
            type: .year,
            old: nil,
            new: "1998",
            conf: 0.69
        ),
        .init(
            id: "change-everything-genre",
            track: "Everything In Its Right Place",
            artist: "Radiohead",
            type: .genre,
            old: "Rock",
            new: "Art Rock",
            conf: 0.82
        ),
        .init(
            id: "change-aria-year",
            track: "Aria",
            artist: "Bach, J.S.",
            type: .year,
            old: nil,
            new: "1741",
            conf: 0.63
        ),
        .init(
            id: "change-xtal-genre",
            track: "Xtal",
            artist: "Aphex Twin",
            type: .genre,
            old: "Electronic",
            new: "Ambient",
            conf: 0.79
        ),
        .init(
            id: "change-pharaohs-dance-genre",
            track: "Pharaoh's Dance",
            artist: "Miles Davis",
            type: .genre,
            old: nil,
            new: "Jazz Fusion",
            conf: 0.48
        ),
        .init(
            id: "change-optimistic-genre",
            track: "Optimistic",
            artist: "Radiohead",
            type: .genre,
            old: "Rock",
            new: "Alternative",
            conf: 0.90
        ),
        .init(
            id: "change-damage-inc-genre",
            track: "Damage, Inc.",
            artist: "Metallica",
            type: .genre,
            old: "Metal",
            new: "Thrash Metal",
            conf: 0.93
        ),
    ]

    let dryRun = (changes: 211, tracks: 198, avgConfidence: 88, genre: 142, year: 69)

    let changeLog: [LogEntry] = [
        .init(
            id: "log-master-puppets-genre",
            time: "8m ago",
            type: .genre,
            track: "Master of Puppets (8 tracks)",
            artist: "Metallica",
            old: "Metal",
            new: "Thrash Metal",
            conf: 0.96
        ),
        .init(
            id: "log-kid-a-year",
            time: "8m ago",
            type: .year,
            track: "Kid A",
            artist: "Radiohead",
            old: "—",
            new: "2000",
            conf: 0.91
        ),
        .init(
            id: "log-kind-of-blue-genre",
            time: "12m ago",
            type: .genre,
            track: "Kind of Blue",
            artist: "Miles Davis",
            old: "Jazz",
            new: "Modal Jazz",
            conf: 0.88
        ),
        .init(
            id: "log-geogaddi-year",
            time: "Yesterday",
            type: .year,
            track: "Geogaddi",
            artist: "Boards of Canada",
            old: "—",
            new: "2002",
            conf: 0.77
        ),
        .init(
            id: "log-syro-revert",
            time: "Yesterday",
            type: .revert,
            track: "Syro",
            artist: "Aphex Twin",
            old: "2015",
            new: "2014",
            conf: 1.0
        ),
        .init(
            id: "log-ok-computer-genre",
            time: "2d ago",
            type: .genre,
            track: "OK Computer",
            artist: "Radiohead",
            old: "Rock",
            new: "Art Rock",
            conf: 0.84
        ),
    ]

    let runHistory: [RunReportRow] = [
        .init(
            id: "run-completed",
            stateLabel: "Completed",
            tone: .success,
            triggerLabel: "Manual check",
            startedLabel: "2m ago",
            durationLabel: "45s",
            changeCountLabel: "12 changes"
        ),
        .init(
            id: "run-completed-no-op",
            stateLabel: "Completed · no changes",
            tone: .neutral,
            triggerLabel: "Background sync",
            startedLabel: "15m ago",
            durationLabel: "38s",
            changeCountLabel: "No changes"
        ),
        .init(
            id: "run-failed",
            stateLabel: "Failed",
            tone: .error,
            triggerLabel: "File system event",
            startedLabel: "1h ago",
            failureSummary: "Music library timed out"
        ),
    ]

    let reportStats = (processed: 211, genres: 142, years: 69)

    let genreDist: [ChartDatum] = [
        .init(id: "genre-thrash-metal", label: "Thrash Metal", count: 38),
        .init(id: "genre-idm", label: "IDM", count: 31),
        .init(id: "genre-art-rock", label: "Art Rock", count: 24),
        .init(id: "genre-modal-jazz", label: "Modal Jazz", count: 19),
        .init(id: "genre-ambient", label: "Ambient", count: 16),
        .init(id: "genre-jazz-fusion", label: "Jazz Fusion", count: 14),
    ]
    let overTime: [ChartDatum] = ["W1", "W2", "W3", "W4", "W5", "W6", "W7", "W8", "W9", "W10", "W11", "W12"]
        .enumerated()
        .map { entry in
            ChartDatum(
                id: "week-\(entry.element)",
                label: entry.element,
                count: [4, 9, 7, 14, 11, 22, 18, 31, 27, 19, 33, 28][entry.offset]
            )
        }
    let yearDist: [ChartDatum] = [
        .init(id: "decade-60s", label: "60s", count: 6),
        .init(id: "decade-70s", label: "70s", count: 11),
        .init(id: "decade-80s", label: "80s", count: 18),
        .init(id: "decade-90s", label: "90s", count: 27),
        .init(id: "decade-00s", label: "00s", count: 22),
        .init(id: "decade-10s", label: "10s", count: 14),
        .init(id: "decade-20s", label: "20s", count: 8),
    ]

    var designSnapshot: DesignDataSnapshot {
        DesignDataSnapshot(
            health: snapshot,
            pipelineActivity: pipelineActivity,
            pendingVerification: pendingVerification,
            coverage: coverage,
            issues: issues,
            metrics: metrics,
            activity: activity,
            artists: artists,
            changes: changes,
            dryRun: DryRunSummary(
                changes: dryRun.changes,
                tracks: dryRun.tracks,
                averageConfidence: dryRun.avgConfidence,
                genre: dryRun.genre,
                year: dryRun.year
            ),
            changeLog: changeLog,
            reportStats: ReportStats(
                processed: reportStats.processed,
                genres: reportStats.genres,
                years: reportStats.years
            ),
            genreDistribution: genreDist,
            updatesOverTime: overTime,
            yearDistribution: yearDist,
            runHistory: runHistory,
            syncStatusText: "Synced 8m ago",
            isPreviewBacked: true
        )
    }
}
