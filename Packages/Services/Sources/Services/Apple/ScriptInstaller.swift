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
import CryptoKit
import Foundation
import OSLog

private let log = AppLogger.make(category: "script-installer")

// MARK: - Errors

public enum ScriptInstallerError: Error, LocalizedError {
    case scriptsDirectoryNotFound
    case bundleScriptsNotFound
    case scriptCopyFailed(scriptName: String, underlyingError: any Error)
    case scriptInstallationIncomplete(errors: [String])
    case allScriptsFailed(errors: [String])

    public var errorDescription: String? {
        switch self {
        case .scriptsDirectoryNotFound:
            "Could not locate the Application Scripts directory. Please ensure the app has proper entitlements."
        case .bundleScriptsNotFound:
            "Script resources not found in the app bundle."
        case let .scriptCopyFailed(name, error):
            "Failed to install script '\(name)': \(error.localizedDescription)"
        case let .scriptInstallationIncomplete(errors):
            "Some required script installations failed:\n\(errors.joined(separator: "\n"))"
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
    // 0o644: NSUserAppleScriptTask reads .scpt files; no exec bit, and not group/world-writable.
    private static let installedScriptPermissions = 0o644

    /// Names of required AppleScript files (without extension).
    public static let requiredScripts = [
        "fetch_tracks",
        "fetch_tracks_by_ids",
        "update_property",
        "batch_update_tracks",
        "fetch_track_ids"
    ]

    /// URL to the Application Scripts directory for this app.
    private let scriptsDirectory: URL
    private let bundleScriptsDirectory: URL?

    public init() throws {
        scriptsDirectory = try FileManager.default.url(
            for: .applicationScriptsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        bundleScriptsDirectory = Bundle.main.resourceURL?.appendingPathComponent("Scripts")
        log.info("Application Scripts directory: \(self.scriptsDirectory.path, privacy: .public)")
    }

    init(scriptsDirectory: URL, bundleScriptsDirectory: URL?) {
        self.scriptsDirectory = scriptsDirectory
        self.bundleScriptsDirectory = bundleScriptsDirectory
    }

    /// Check if all required scripts are installed and match the bundled copies.
    ///
    /// A stale or unreadable script is treated as not installed so startup can repair it.
    public func areScriptsInstalled() -> Bool {
        scriptsNeedingInstall().isEmpty
    }

    /// Check whether every installed script is readable and byte-identical to the bundled script.
    public func areScriptsCurrent() -> Bool {
        scriptsNeedingInstall().isEmpty
    }

    /// Scripts that are missing or differ from the bundled copy.
    public func scriptsNeedingInstall() -> [String] {
        Self.requiredScripts.filter { name in
            guard let sourceURL = bundledScriptURL(for: name),
                  FileManager.default.fileExists(atPath: sourceURL.path)
            else {
                return true
            }

            guard let destinationURL = versionedScriptURL(for: name, sourceURL: sourceURL) else {
                return true
            }

            guard installedScriptMatches(sourceURL: sourceURL, destinationURL: destinationURL) else {
                return true
            }

            return false
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
        guard let bundleScriptsURL = bundleScriptsDirectory else {
            throw ScriptInstallerError.bundleScriptsNotFound
        }

        var installed: [String] = []
        var errors: [String] = []

        for scriptName in Self.requiredScripts {
            let sourceURL = bundleScriptsURL.appendingPathComponent("\(scriptName).scpt")

            do {
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    let msg = "Pre-compiled script '\(scriptName).scpt' not found in bundle"
                    errors.append(msg)
                    log.warning("\(msg, privacy: .public)")
                    continue
                }

                guard let destinationURL = versionedScriptURL(for: scriptName, sourceURL: sourceURL) else {
                    let msg = "Could not fingerprint bundled script '\(scriptName).scpt'"
                    errors.append(msg)
                    log.warning("\(msg, privacy: .public)")
                    continue
                }

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    guard !installedScriptMatches(sourceURL: sourceURL, destinationURL: destinationURL) else {
                        try setInstalledScriptPermissions(destinationURL)
                        installed.append(scriptName)
                        continue
                    }
                    try FileManager.default.removeItem(at: destinationURL)
                }

                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                try setInstalledScriptPermissions(destinationURL)
                removeLegacyScriptIfPossible(named: scriptName, currentURL: destinationURL)
                installed.append(scriptName)
                log.info("Installed script: \(scriptName, privacy: .public)")
            } catch {
                let msg = "Failed to install '\(scriptName)': \(error.localizedDescription)"
                errors.append(msg)
                log.error("\(msg, privacy: .public)")
            }
        }

        if !errors.isEmpty {
            if installed.isEmpty {
                throw ScriptInstallerError.allScriptsFailed(errors: errors)
            }
            throw ScriptInstallerError.scriptInstallationIncomplete(errors: errors)
        }

        log.info("Script installation complete: \(installed.count)/\(Self.requiredScripts.count) installed")
        return installed
    }

    private func installedScriptMatches(sourceURL: URL, destinationURL: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: destinationURL.path) else {
            return false
        }

        return FileManager.default.contentsEqual(
            atPath: sourceURL.path,
            andPath: destinationURL.path
        )
    }

    private func setInstalledScriptPermissions(_ scriptURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.installedScriptPermissions],
            ofItemAtPath: scriptURL.path
        )
    }

    /// URL for a specific script in the Application Scripts directory.
    public func scriptURL(for scriptName: String) -> URL {
        guard let sourceURL = bundledScriptURL(for: scriptName),
              let versionedURL = versionedScriptURL(for: scriptName, sourceURL: sourceURL)
        else {
            return legacyScriptURL(for: scriptName)
        }

        return versionedURL
    }

    private func bundledScriptURL(for scriptName: String) -> URL? {
        bundleScriptsDirectory?.appendingPathComponent("\(scriptName).scpt")
    }

    private func versionedScriptURL(for scriptName: String, sourceURL: URL) -> URL? {
        guard let fingerprint = scriptFingerprint(for: sourceURL) else {
            return nil
        }

        return scriptsDirectory.appendingPathComponent("\(scriptName)-\(fingerprint).scpt")
    }

    private func legacyScriptURL(for scriptName: String) -> URL {
        scriptsDirectory.appendingPathComponent("\(scriptName).scpt")
    }

    private func scriptFingerprint(for sourceURL: URL) -> String? {
        guard let data = try? Data(contentsOf: sourceURL) else {
            return nil
        }

        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func removeLegacyScriptIfPossible(named scriptName: String, currentURL: URL) {
        let legacyURL = legacyScriptURL(for: scriptName)
        guard legacyURL != currentURL,
              FileManager.default.fileExists(atPath: legacyURL.path)
        else {
            return
        }

        try? FileManager.default.removeItem(at: legacyURL)
    }
}
