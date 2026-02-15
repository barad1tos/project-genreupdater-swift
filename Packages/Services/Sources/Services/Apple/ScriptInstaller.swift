// ScriptInstaller.swift — Install AppleScript files into sandbox directory
// NEW: No Python equivalent (Python runs outside sandbox)
//
// macOS sandbox requires scripts to live in a specific directory:
//   ~/Library/Application Scripts/<bundle-id>/
//
// NSUserAppleScriptTask can ONLY run scripts from this directory.
// This installer copies compiled .scpt files from the app bundle's
// Resources/Scripts/ into that directory during first launch.

import Core
import Foundation
import OSLog

private let log = AppLogger.make(category: "script-installer")

// MARK: - Errors

public enum ScriptInstallerError: Error, LocalizedError {
    case scriptsDirectoryNotFound
    case bundleScriptsNotFound
    case scriptCopyFailed(scriptName: String, underlyingError: any Error)
    case scriptCompilationFailed(scriptName: String, detail: String)
    case allScriptsFailed(errors: [String])

    public var errorDescription: String? {
        switch self {
        case .scriptsDirectoryNotFound:
            "Could not locate the Application Scripts directory. Please ensure the app has proper entitlements."
        case .bundleScriptsNotFound:
            "Script resources not found in the app bundle."
        case let .scriptCopyFailed(name, error):
            "Failed to install script '\(name)': \(error.localizedDescription)"
        case let .scriptCompilationFailed(name, detail):
            "Failed to compile script '\(name)': \(detail)"
        case let .allScriptsFailed(errors):
            "All script installations failed:\n\(errors.joined(separator: "\n"))"
        }
    }
}

// MARK: - Script Installer

/// Manages installation of AppleScript files into the sandboxed Application Scripts directory.
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
        log.info("Application Scripts directory: \(self.scriptsDirectory.path())")
    }

    /// Check if all required scripts are installed.
    public func areScriptsInstalled() -> Bool {
        Self.requiredScripts.allSatisfy { name in
            let url = scriptsDirectory.appendingPathComponent("\(name).scpt")
            return FileManager.default.fileExists(atPath: url.path())
        }
    }

    /// Get the list of missing scripts.
    public func missingScripts() -> [String] {
        Self.requiredScripts.filter { name in
            let url = scriptsDirectory.appendingPathComponent("\(name).scpt")
            return !FileManager.default.fileExists(atPath: url.path())
        }
    }

    /// Install all AppleScript files from the app bundle to the Application Scripts directory.
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
                if FileManager.default.fileExists(atPath: destinationURL.path()) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                // If compiled .scpt exists in bundle, copy it
                if FileManager.default.fileExists(atPath: sourceURL.path()) {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    installed.append(scriptName)
                    log.info("Installed script: \(scriptName, privacy: .public)")
                } else {
                    // Try .applescript source and compile it
                    let sourceScriptURL = bundleScriptsURL.appendingPathComponent("\(scriptName).applescript")
                    if FileManager.default.fileExists(atPath: sourceScriptURL.path()) {
                        try compileAndInstall(source: sourceScriptURL, destination: destinationURL, name: scriptName)
                        installed.append(scriptName)
                        log.info("Compiled and installed script: \(scriptName, privacy: .public)")
                    } else {
                        let msg = "Script '\(scriptName)' not found in bundle (checked .scpt and .applescript)"
                        errors.append(msg)
                        log.warning("\(msg, privacy: .public)")
                    }
                }
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

    /// Compile an .applescript source file into .scpt and copy to destination.
    private func compileAndInstall(source: URL, destination: URL, name: String) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osacompile")
        process.arguments = ["-o", destination.path(), source.path()]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ScriptInstallerError.scriptCompilationFailed(scriptName: name, detail: errorOutput)
        }
    }

    /// URL for a specific script in the Application Scripts directory.
    public func scriptURL(for scriptName: String) -> URL {
        scriptsDirectory.appendingPathComponent("\(scriptName).scpt")
    }
}
