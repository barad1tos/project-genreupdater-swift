// MusicLibraryReader.swift — semantic access to the MusicKit presentation catalog.

import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "music-reader")

public enum MusicLibraryError: Error, LocalizedError {
    case authorizationDenied
    case authorizationRestricted
    case fetchFailed(detail: String)
    case musicAppNotAvailable

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Music library access was denied. "
                + "Please grant access in System Settings > "
                + "Privacy & Security > Media & Apple Music."
        case .authorizationRestricted:
            "Music library access is restricted on this device."
        case let .fetchFailed(detail):
            "Failed to read music library: \(detail)"
        case .musicAppNotAvailable:
            "Music app is not available on this system."
        }
    }
}

/// Reads the user's MusicKit presentation catalog without creating processing tracks.
public actor MusicLibraryReader: MusicCatalogReading {
    private let source: any MusicKitCatalogSource

    public init() {
        source = MusicKitCatalogAdapter()
    }

    init(source: any MusicKitCatalogSource) {
        self.source = source
    }

    public var isAuthorized: Bool {
        get async {
            await source.isAuthorized
        }
    }

    public func requestAuthorization() async throws {
        try await source.requestAuthorization()
        log.info("Music library access authorized")
    }

    public func loadCatalog(testArtists: [String] = []) async throws -> CatalogSnapshot {
        if await !isAuthorized {
            try await requestAuthorization()
        }

        let signpostState = AppSignpost.libraryLoad.beginInterval("loadCatalog")
        defer { AppSignpost.libraryLoad.endInterval("loadCatalog", signpostState) }

        do {
            let metadata = try await source.loadTracks()
            let snapshot = MusicKitCatalogAdapter.makeSnapshot(
                from: metadata,
                testArtists: testArtists
            )
            log.info("Fetched \(snapshot.tracks.count, privacy: .public) catalog tracks from MusicKit")
            return snapshot
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("MusicKit catalog fetch failed: \(error.localizedDescription, privacy: .public)")
            throw MusicLibraryError.fetchFailed(detail: error.localizedDescription)
        }
    }

    public func trackCount() async throws -> Int {
        try await source.trackCount()
    }
}
