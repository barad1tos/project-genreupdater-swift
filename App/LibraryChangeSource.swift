import Core
import Foundation

/// An event source for library-change automation (ADR 0003 watch/hybrid).
/// The in-process implementation watches the Music library file; the
/// slice-14 launchd agent (WatchPaths) becomes the windowless source.
protocol LibraryChangeSource: Sendable {
    /// False when the environment cannot observe the library file right
    /// now (the App Store sandbox blocks direct reads of ~/Music, or the
    /// library does not exist yet) — the runtime then degrades honestly
    /// instead of arming a dead watcher. Re-probed on every apply.
    var isAvailable: Bool { get }

    /// One element per observed library mutation. The stream FINISHES
    /// after a rename/delete event (the vnode is gone — the consumer
    /// re-arms on the path) or when the source is torn down.
    func events() -> AsyncStream<Void>
}

/// DispatchSource-backed watcher on the Music library package. Each
/// `events()` call opens its own descriptor and closes it in the cancel
/// handler (Apple's documented order for fd sources), so re-arms and
/// teardown never race a shared fd.
final class MusicLibraryFileWatcher: LibraryChangeSource {
    private let path: String

    init(libraryPath: String) {
        path = (libraryPath as NSString).expandingTildeInPath
            .replacingOccurrences(of: "${HOME}", with: NSHomeDirectory())
    }

    var isAvailable: Bool {
        access(path, F_OK) == 0
    }

    func events() -> AsyncStream<Void> {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            return AsyncStream { $0.finish() }
        }
        return AsyncStream { continuation in
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .global(qos: .utility)
            )
            source.setEventHandler {
                let data = source.data
                continuation.yield()
                if !data.isDisjoint(with: [.rename, .delete]) {
                    // The vnode is going away — further writes to the
                    // replacement file are invisible on this descriptor.
                    continuation.finish()
                }
            }
            source.setCancelHandler {
                close(descriptor)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.resume()
        }
    }
}
