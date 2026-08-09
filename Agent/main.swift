import Foundation
import OSLog

// The thin waker (ADR 0003, slice 14): watches the Music library file and
// nudges the app; the pipeline, throttling policy, and records all live in
// the app process. Replaced with the real watcher in the next task.
let log = Logger(subsystem: "com.genreupdater.agent", category: "waker")
log.info("Genre Updater agent started")
dispatchMain()
