import Core
import Foundation

/// An event source for library-change automation (ADR 0003 watch/hybrid).
/// The in-process implementation watches the Music library file; the
/// slice-14 launchd agent (WatchPaths) becomes the windowless source.
protocol LibraryChangeSource: Sendable {
    /// False when the environment cannot observe the library file (the
    /// App Store sandbox blocks direct reads of ~/Music) — the runtime
    /// then degrades honestly instead of arming a dead watcher.
    var isAvailable: Bool { get }

    /// One element per observed library mutation; finishes when the
    /// source is torn down.
    func events() -> AsyncStream<Void>
}

/// DispatchSource-backed watcher on the Music library package. The
/// availability probe IS the open(2) call: outside the sandbox it
/// succeeds, inside it fails and `isAvailable` reports false.
final class MusicLibraryFileWatcher: LibraryChangeSource {
    private let fileDescriptor: Int32

    init(libraryPath: String) {
        let expanded = (libraryPath as NSString).expandingTildeInPath
            .replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
        fileDescriptor = open(expanded, O_EVTONLY)
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    var isAvailable: Bool {
        fileDescriptor >= 0
    }

    func events() -> AsyncStream<Void> {
        guard fileDescriptor >= 0 else {
            return AsyncStream { $0.finish() }
        }
        let descriptor = fileDescriptor
        return AsyncStream { continuation in
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                continuation.yield()
            }
            source.setCancelHandler {
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }
}
