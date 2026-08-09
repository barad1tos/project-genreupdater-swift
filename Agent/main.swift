import AppKit
import Foundation
import OSLog

/// The thin waker (ADR 0003, slice 14): watches the Music library file and
/// nudges the app through its URL scheme; the pipeline, gating, throttling
/// policy, and run records all live in the app process. Self-contained on
/// purpose — the app-target watcher is SwiftUI-runtime glue this tool must
/// not drag in.
private let log = Logger(subsystem: "com.genreupdater.agent", category: "waker")

/// The sandbox rewrites NSHomeDirectory to the container; the library
/// lives under the REAL user home, readable via assets.music.read-only.
private func realHomeDirectory() -> String {
    guard let home = getpwuid(getuid())?.pointee.pw_dir else {
        return NSHomeDirectory()
    }
    return String(cString: home)
}

private let libraryPath = realHomeDirectory() + "/Music/Music/Music Library.musiclibrary"
private let wakeURLString = "genreupdater://automation/library-change"
/// Python launchd ThrottleInterval parity, in-process: the plist key only
/// throttles job relaunches, so event coalescing lives here.
private let wakeThrottleInterval: TimeInterval = 300
// Safety: both vars are confined to stateQueue — armWatch runs on it and
// every dispatch-source handler targets it; nothing touches them elsewhere.
nonisolated(unsafe) private var lastWakeAt: Date?
nonisolated(unsafe) private var activeSource: DispatchSourceFileSystemObject?
private let stateQueue = DispatchQueue(label: "com.genreupdater.agent.state")

private func nudgeApp() {
    if let lastWakeAt, Date().timeIntervalSince(lastWakeAt) < wakeThrottleInterval {
        // The app-side watch path owns defer semantics; a dropped
        // in-window nudge is safe because the app re-observes on the
        // next wake and launchd relaunches us if we die.
        return
    }
    guard let wakeURL = URL(string: wakeURLString) else {
        log.error("Wake URL failed to parse; the scheme constant is broken")
        return
    }
    lastWakeAt = Date()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    NSWorkspace.shared.open(wakeURL, configuration: configuration) { _, error in
        if let error {
            log.error("Wake failed: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("Nudged the app after a library change")
        }
    }
}

/// Opens a descriptor per watch generation and re-opens after rename or
/// delete replaces the vnode (the slice-13 watcher contract). A missing
/// file parks on a retry timer instead of crash-looping under KeepAlive.
private func armWatch() {
    let descriptor = open(libraryPath, O_EVTONLY)
    guard descriptor >= 0 else {
        log.info("Library file not observable; retrying in 60s")
        stateQueue.asyncAfter(deadline: .now() + 60) { armWatch() }
        return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .rename, .delete],
        queue: stateQueue
    )
    source.setEventHandler {
        let data = source.data
        nudgeApp()
        if !data.isDisjoint(with: [.rename, .delete]) {
            source.cancel()
        }
    }
    source.setCancelHandler {
        close(descriptor)
        activeSource = nil
        // The vnode died — re-arm on the path after a beat.
        stateQueue.asyncAfter(deadline: .now() + 5) { armWatch() }
    }
    activeSource = source
    source.resume()
    log.info("Watching the Music library for changes")
}

log.info("Genre Updater agent started")
stateQueue.async { armWatch() }
dispatchMain()
