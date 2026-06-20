import Testing
@testable import Core

// MARK: - TrackKind Enum Tests

@Suite("TrackKind — description, editability, and processing availability")
struct TrackKindTests {
    @Test(
        "description returns expected human-readable string",
        arguments: zip(
            TrackKind.allCases,
            [
                "Local Only",
                "Purchased",
                "Matched",
                "Uploaded",
                "Subscription",
                "Downloaded",
                "Pre-release",
                "No Longer Available",
            ]
        )
    )
    func description(kind: TrackKind, expected: String) {
        #expect(kind.description == expected)
    }

    @Test(
        "canEditMetadata is false only for prerelease status",
        arguments: TrackKind.allCases
    )
    func canEditMetadata(kind: TrackKind) {
        if kind == .prerelease {
            #expect(!kind.canEditMetadata)
        } else {
            #expect(kind.canEditMetadata)
        }
    }

    @Test(
        "isAvailableForProcessing is true only for processable statuses",
        arguments: TrackKind.allCases
    )
    func isAvailableForProcessing(kind: TrackKind) {
        if kind == .prerelease || kind == .noLongerAvailable {
            #expect(!kind.isAvailableForProcessing)
        } else {
            #expect(kind.isAvailableForProcessing)
        }
    }
}

// MARK: - init(rawConstant:) Tests

@Suite("TrackKind.init(rawConstant:) — AppleScript constant mapping")
struct TrackKindRawConstantTests {
    @Test(
        "4-char AppleScript codes map to correct TrackKind",
        arguments: [
            ("ksub", TrackKind.subscription),
            ("kpre", TrackKind.prerelease),
            ("kloc", TrackKind.localOnly),
            ("kpur", TrackKind.purchased),
            ("kmat", TrackKind.matched),
            ("kupl", TrackKind.uploaded),
            ("kdwn", TrackKind.downloaded),
        ]
    )
    func appleScriptCodeMapping(code: String, expected: TrackKind) {
        #expect(TrackKind(rawConstant: code) == expected)
    }

    @Test("Case insensitive: uppercase KSUB maps to subscription")
    func caseInsensitive() {
        #expect(TrackKind(rawConstant: "KSUB") == .subscription)
    }

    @Test("Full AppleScript format maps correctly via contains check")
    func fullAppleScriptFormat() {
        #expect(TrackKind(rawConstant: "«constant ****kSub»") == .subscription)
    }

    @Test("Unknown code returns nil")
    func unknownCode() {
        #expect(TrackKind(rawConstant: "kxxx") == nil)
    }
}

// MARK: - normalizeTrackStatus Tests

@Suite("normalizeTrackStatus — raw string normalization")
struct NormalizeTrackStatusTests {
    @Test("nil input returns nil")
    func nilInput() {
        #expect(normalizeTrackStatus(nil) == nil)
    }

    @Test("Empty string returns nil")
    func emptyString() {
        #expect(normalizeTrackStatus("") == nil)
    }

    @Test("Whitespace-only string returns nil")
    func whitespaceOnly() {
        #expect(normalizeTrackStatus("   ") == nil)
    }

    @Test("Direct rawValue match: subscription")
    func directRawValue() {
        #expect(normalizeTrackStatus("subscription") == .subscription)
    }

    @Test("Case insensitive rawValue: Subscription")
    func caseInsensitiveRawValue() {
        #expect(normalizeTrackStatus("Subscription") == .subscription)
    }

    @Test("Multi-word rawValue: local only")
    func multiWordRawValue() {
        #expect(normalizeTrackStatus("local only") == .localOnly)
    }

    @Test("AppleScript constant format normalizes correctly")
    func appleScriptConstant() {
        #expect(normalizeTrackStatus("«constant ****kSub»") == .subscription)
    }

    @Test("Music unavailable status normalizes correctly")
    func noLongerAvailableStatus() {
        #expect(normalizeTrackStatus("No Longer Available") == .noLongerAvailable)
    }

    @Test("Unknown string returns nil")
    func unknownString() {
        #expect(normalizeTrackStatus("foobar") == nil)
    }
}

// MARK: - filterAvailableTracks Tests

@Suite("filterAvailableTracks — status-based filtering")
struct FilterAvailableTracksTests {
    @Test("Mixed statuses: filters out non-processable tracks")
    func mixedStatuses() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Z", trackStatus: nil),
            Track(id: "2", name: "B", artist: "X", album: "Z", trackStatus: "subscription"),
            Track(id: "3", name: "C", artist: "X", album: "Z", trackStatus: "prerelease"),
            Track(id: "4", name: "D", artist: "X", album: "Z", trackStatus: "no longer available"),
        ]
        let result = filterAvailableTracks(tracks)
        #expect(result.count == 2)
        #expect(result.map(\.id) == ["1", "2"])
    }

    @Test("Empty array returns empty array")
    func emptyArray() {
        #expect(filterAvailableTracks([]).isEmpty)
    }

    @Test("All nil statuses returns all tracks")
    func allNilStatuses() {
        let tracks = [
            Track(id: "1", name: "A", artist: "X", album: "Z", trackStatus: nil),
            Track(id: "2", name: "B", artist: "X", album: "Z", trackStatus: nil),
        ]
        let result = filterAvailableTracks(tracks)
        #expect(result.count == 2)
    }
}
