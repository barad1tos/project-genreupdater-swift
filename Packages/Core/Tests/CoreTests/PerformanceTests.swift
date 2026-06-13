// PerformanceTests.swift — Performance regression tests for Core algorithms
//
// Uses XCTestCase with measure {} blocks (Swift Testing doesn't support these yet).
// These tests establish baselines for critical hot paths:
// - Genre determination across 50 tracks
// - Year scoring with 20 candidates
// - String normalization at scale
// - Track Codable round-trip throughput

import XCTest
@testable import Core

final class CorePerformanceTests: XCTestCase {
    func testGenreDetermination50Tracks() {
        let genres = ["Rock", "Metal", "Pop", "Jazz", "Electronic"]
        let tracks = (0 ..< 50).map { index in
            Track(
                id: "T\(index)",
                name: "Track \(index)",
                artist: "TestArtist",
                album: "Album \(index % 5)",
                genre: genres[index % 5],
                year: 2000 + (index % 20),
                dateAdded: Date(timeIntervalSince1970: Double(index) * 86400)
            )
        }
        let determinator = GenreDeterminator()

        measure {
            _ = determinator.determineDominantGenre(artistTracks: tracks)
        }
    }

    func testYearScoring20Candidates() {
        let candidates = (0 ..< 20).map { index in
            ReleaseCandidate(
                artist: "Artist",
                album: "Album",
                year: 1980 + index,
                source: .musicBrainz
            )
        }
        let track = Track(
            id: "T1",
            name: "Song",
            artist: "Artist",
            album: "Album",
            year: 1990
        )
        let determinator = YearDeterminator()

        measure {
            _ = determinator.determineYear(candidates: candidates, track: track)
        }
    }

    func testNormalization100Strings() {
        let strings = (0 ..< 100).map {
            "Test String #\($0) (Remastered) [Deluxe Edition]"
        }

        measure {
            for string in strings {
                _ = normalizeForMatching(string)
            }
        }
    }

    func testTrackCodable1000() {
        let tracks = (0 ..< 1000).map { index in
            Track(
                id: "T\(index)",
                name: "Track \(index)",
                artist: "Artist \(index % 10)",
                album: "Album \(index % 50)",
                genre: "Rock",
                year: 2000
            )
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        measure {
            for track in tracks {
                guard let data = try? encoder.encode(track) else { continue }
                _ = try? decoder.decode(Track.self, from: data)
            }
        }
    }
}
