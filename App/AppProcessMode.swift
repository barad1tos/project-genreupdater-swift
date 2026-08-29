import Foundation
import Services

enum AppProcessMode: Equatable {
    case application
    case unitTestHost

    static let current = Self(environment: ProcessInfo.processInfo.environment)

    init(environment: [String: String]) {
        self = environment["XCTestConfigurationFilePath"] == nil ? .application : .unitTestHost
    }

    var shouldUsePersistentStorage: Bool {
        self == .application
    }

    var shouldStartLiveServices: Bool {
        self == .application
    }
}

func makeProcessMusicCatalog() -> any MusicCatalogReading {
    switch AppProcessMode.current {
    case .application:
        MusicLibraryReader()
    case .unitTestHost:
        InactiveMusicCatalog()
    }
}

private actor InactiveMusicCatalog: MusicCatalogReading {
    var isAuthorized: Bool {
        false
    }

    func requestAuthorization() async throws {
        throw MusicLibraryError.musicAppNotAvailable
    }

    func loadCatalog(testArtists _: [String]) async throws -> CatalogSnapshot {
        throw MusicLibraryError.musicAppNotAvailable
    }

    func trackCount() async throws -> Int {
        throw MusicLibraryError.musicAppNotAvailable
    }
}
