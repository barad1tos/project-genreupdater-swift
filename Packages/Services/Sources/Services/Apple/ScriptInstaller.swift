// ScriptInstaller.swift — Install pre-compiled AppleScript files into sandbox directory
// NEW: No Python equivalent (Python runs outside sandbox)
//
// macOS sandbox requires scripts to live in a specific directory:
//   ~/Library/Application Scripts/<bundle-id>/
//
// NSUserAppleScriptTask can ONLY run scripts from this directory.
// The build phase compiles .applescript → .scpt via osacompile, then this
// installer copies the pre-compiled .scpt files from the app bundle's
// Resources/Scripts/ into that directory during first launch.
//
// NOTE: Sandboxed apps cannot spawn subprocesses (Process/osacompile),
// so all compilation must happen at build time — never at runtime.

import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "script-installer")

// MARK: - Errors

public enum ScriptInstallerError: Error, LocalizedError {
    case scriptsDirectoryNotFound
    case bundleScriptsNotFound
    case scriptCopyFailed(scriptName: String, underlyingError: any Error)
    case allScriptsFailed(errors: [String])

    public var errorDescription: String? {
        switch self {
        case .scriptsDirectoryNotFound:
            "Could not locate the Application Scripts directory. Please ensure the app has proper entitlements."
        case .bundleScriptsNotFound:
            "Script resources not found in the app bundle."
        case let .scriptCopyFailed(name, error):
            "Failed to install script '\(name)': \(error.localizedDescription)"
        case let .allScriptsFailed(errors):
            "All script installations failed:\n\(errors.joined(separator: "\n"))"
        }
    }
}

// MARK: - Script Installer

/// Manages installation of pre-compiled AppleScript files into the sandboxed Application Scripts directory.
///
/// Scripts are compiled from `.applescript` to `.scpt` at build time via a post-build script
/// in `project.yml`. This actor copies those pre-compiled `.scpt` files from the app bundle
/// into `~/Library/Application Scripts/<bundle-id>/` where `NSUserAppleScriptTask` can run them.
public actor ScriptInstaller {
    /// Names of required AppleScript files (without extension).
    public static let requiredScripts = [
        "fetch_tracks",
        "fetch_tracks_by_ids",
        "update_property",
        "batch_update_tracks",
        "fetch_track_ids",
    ]

    /// URL to the Application Scripts directory for this app.
    private let scriptsDirectory: URL

    public init() throws {
        scriptsDirectory = try FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        log.info("Application Scripts directory: \(self.scriptsDirectory.path, privacy: .public)")
    }

    /// Check if all required scripts are installed.
    public func areScriptsInstalled() -> Bool {
        Self.requiredScripts.allSatisfy { name in
            let url = scriptsDirectory.appendingPathComponent("\(name).scpt")
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Get the list of missing scripts.
    public func missingScripts() -> [String] {
        Self.requiredScripts.filter { name in
            let url = scriptsDirectory.appendingPathComponent("\(name).scpt")
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Copy all pre-compiled `.scpt` files from the app bundle to the Application Scripts directory.
    ///
    /// The bundle must contain compiled `.scpt` files (produced by the build-time `osacompile` step).
    /// Sandboxed apps cannot compile scripts at runtime — `Process` is blocked by the sandbox.
    @discardableResult
    public func installScripts() throws -> [String] {
        guard let bundleScriptsURL = Bundle.main.resourceURL?.appendingPathComponent("Scripts") else {
            throw ScriptInstallerError.bundleScriptsNotFound
        }

        var installed: [String] = []
        var errors: [String] = []

        for scriptName in Self.requiredScripts {
            let sourceURL = bundleScriptsURL.appendingPathComponent("\(scriptName).scpt")
            let destinationURL = scriptsDirectory.appendingPathComponent("\(scriptName).scpt")

            do {
                // Remove existing file if present (for updates)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    let msg = "Pre-compiled script '\(scriptName).scpt' not found in bundle"
                    errors.append(msg)
                    log.warning("\(msg, privacy: .public)")
                    continue
                }

                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                installed.append(scriptName)
                log.info("Installed script: \(scriptName, privacy: .public)")
            } catch {
                let msg = "Failed to install '\(scriptName)': \(error.localizedDescription)"
                errors.append(msg)
                log.error("\(msg, privacy: .public)")
            }
        }

        if installed.isEmpty, !errors.isEmpty {
            throw ScriptInstallerError.allScriptsFailed(errors: errors)
        }

        log.info("Script installation complete: \(installed.count)/\(Self.requiredScripts.count) installed")
        return installed
    }

    /// URL for a specific script in the Application Scripts directory.
    public func scriptURL(for scriptName: String) -> URL {
        scriptsDirectory.appendingPathComponent("\(scriptName).scpt")
    }
}
