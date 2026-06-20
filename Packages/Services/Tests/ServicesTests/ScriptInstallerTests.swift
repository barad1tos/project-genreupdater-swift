import Foundation
import Testing
@testable import Services

@Suite("ScriptInstaller — installed script freshness")
struct ScriptInstallerTests {
    @Test("Missing installed script requires installation")
    func missingInstalledScriptRequiresInstallation() async throws {
        let fixture = try ScriptInstallerFixture()
        try fixture.writeBundledScripts()
        let installer = fixture.makeInstaller()
        try await fixture.writeInstalledScripts(using: installer, excluding: ["fetch_tracks"])

        let scriptsNeedingInstall = await installer.scriptsNeedingInstall()

        #expect(scriptsNeedingInstall == ["fetch_tracks"])
        #expect(await installer.areScriptsCurrent() == false)
    }

    @Test("Stale installed script requires installation")
    func staleInstalledScriptRequiresInstallation() async throws {
        let fixture = try ScriptInstallerFixture()
        try fixture.writeBundledScripts(overrides: ["fetch_tracks": "old fetch_tracks"])
        let installer = fixture.makeInstaller()
        try await fixture.writeInstalledScripts(using: installer)
        try fixture.writeBundledScripts()

        let scriptsNeedingInstall = await installer.scriptsNeedingInstall()

        #expect(scriptsNeedingInstall == ["fetch_tracks"])
        #expect(await installer.areScriptsCurrent() == false)
    }

    @Test("Matching installed scripts are current")
    func matchingInstalledScriptsAreCurrent() async throws {
        let fixture = try ScriptInstallerFixture()
        try fixture.writeBundledScripts()
        let installer = fixture.makeInstaller()
        try await fixture.writeInstalledScripts(using: installer)

        #expect(await installer.scriptsNeedingInstall().isEmpty)
        #expect(await installer.areScriptsCurrent())
    }

    @Test("Installation replaces stale scripts from bundle")
    func installationReplacesStaleScriptsFromBundle() async throws {
        let fixture = try ScriptInstallerFixture()
        try fixture.writeBundledScripts(overrides: ["fetch_tracks": "old fetch_tracks"])
        let installer = fixture.makeInstaller()
        try await fixture.writeInstalledScripts(using: installer)
        try fixture.writeBundledScripts()

        let installedScripts = try await installer.installScripts()

        #expect(installedScripts == ScriptInstaller.requiredScripts)
        #expect(await installer.areScriptsCurrent())
        let installedContents = try await fixture.installedContents(for: "fetch_tracks", using: installer)
        #expect(installedContents == fixture.bundledContents(for: "fetch_tracks"))
    }

    @Test("Legacy fixed-name script does not block current versioned installation")
    func legacyScriptDoesNotBlockVersionedInstallation() async throws {
        let fixture = try ScriptInstallerFixture()
        try fixture.writeBundledScripts()
        try fixture.writeLegacyInstalledScript(named: "fetch_tracks", contents: "old fetch_tracks")
        let installer = fixture.makeInstaller()

        let installedScripts = try await installer.installScripts()

        #expect(installedScripts == ScriptInstaller.requiredScripts)
        #expect(await installer.areScriptsCurrent())
        let installedContents = try await fixture.installedContents(for: "fetch_tracks", using: installer)
        #expect(installedContents == fixture.bundledContents(for: "fetch_tracks"))
    }
}

private struct ScriptInstallerFixture {
    let root: URL
    let installedScriptsDirectory: URL
    let bundledScriptsDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptInstallerTests-\(UUID().uuidString)", isDirectory: true)
        installedScriptsDirectory = root.appendingPathComponent("Installed", isDirectory: true)
        bundledScriptsDirectory = root.appendingPathComponent("BundleScripts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installedScriptsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundledScriptsDirectory,
            withIntermediateDirectories: true
        )
    }

    func makeInstaller() -> ScriptInstaller {
        ScriptInstaller(
            scriptsDirectory: installedScriptsDirectory,
            bundleScriptsDirectory: bundledScriptsDirectory
        )
    }

    func writeBundledScripts(overrides: [String: String] = [:]) throws {
        for scriptName in ScriptInstaller.requiredScripts {
            let contents = overrides[scriptName] ?? bundledContents(for: scriptName)
            try contents.write(
                to: bundledURL(for: scriptName),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func writeInstalledScripts(
        using installer: ScriptInstaller,
        excluding excludedScripts: Set<String> = [],
        overrides: [String: String] = [:]
    ) async throws {
        for scriptName in ScriptInstaller.requiredScripts where !excludedScripts.contains(scriptName) {
            let contents = overrides[scriptName] ?? bundledContents(for: scriptName)
            let destinationURL = await installer.scriptURL(for: scriptName)
            try contents.write(
                to: destinationURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func writeLegacyInstalledScript(named scriptName: String, contents: String) throws {
        try contents.write(
            to: legacyInstalledURL(for: scriptName),
            atomically: true,
            encoding: .utf8
        )
    }

    func installedContents(for scriptName: String, using installer: ScriptInstaller) async throws -> String {
        let scriptURL = await installer.scriptURL(for: scriptName)
        return try String(contentsOf: scriptURL, encoding: .utf8)
    }

    func bundledContents(for scriptName: String) -> String {
        "current \(scriptName)"
    }

    private func bundledURL(for scriptName: String) -> URL {
        bundledScriptsDirectory.appendingPathComponent("\(scriptName).scpt")
    }

    private func legacyInstalledURL(for scriptName: String) -> URL {
        installedScriptsDirectory.appendingPathComponent("\(scriptName).scpt")
    }
}
