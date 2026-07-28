import Darwin
import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func expectSuccess(
    _ result: Result<Void, LaunchAgentManagerError>,
    _ message: String
) {
    switch result {
    case .success:
        expect(true, message)
    case .failure(let error):
        expect(false, "\(message) (\(error.localizedDescription))")
    }
}

private func expectUnstableLocation(
    _ result: Result<Void, LaunchAgentManagerError>,
    _ message: String
) {
    switch result {
    case .success:
        expect(false, message)
    case .failure(let error):
        expect(error == .unstableApplicationLocation, message)
        expect(
            error.localizedDescription.contains("Applications") &&
                error.localizedDescription.contains("reopen"),
            "\(message) provides actionable recovery"
        )
    }
}

private func expectUpdateFailure(
    _ result: Result<Void, LaunchAgentManagerError>,
    _ message: String
) {
    switch result {
    case .success:
        expect(false, message)
    case .failure(let error):
        expect(error == .unableToUpdateLoginItem, message)
        expect(
            error.localizedDescription.contains("LaunchAgents") &&
                error.localizedDescription.contains("try again"),
            "\(message) provides actionable recovery"
        )
    }
}

private func expectMigrationFailure(
    _ result: Result<Void, LaunchAgentManagerError>,
    _ message: String
) {
    switch result {
    case .success:
        expect(false, message)
    case .failure(let error):
        expect(error == .unableToMigrateLoginItem, message)
        expect(
            error.localizedDescription.contains("previous login item") &&
                error.localizedDescription.contains("Settings"),
            "\(message) explains the preserved recovery path"
        )
    }
}

private func expectRecoveryFailure(
    _ result: Result<Void, LaunchAgentManagerError>,
    _ message: String
) {
    switch result {
    case .success:
        expect(false, message)
    case .failure(let error):
        expect(error == .unableToRestoreLoginItem, message)
        expect(
            error.localizedDescription.contains("duplicate launches") &&
                error.localizedDescription.contains("off and on again"),
            "\(message) explains manual recovery"
        )
    }
}

private func plist(at url: URL) -> [String: Any]? {
    guard
        let data = try? Data(contentsOf: url),
        let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
    else {
        return nil
    }
    return value as? [String: Any]
}

private func writePlist(_ value: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: value,
        format: .xml,
        options: 0
    )
    try data.write(to: url, options: .atomic)
}

private func makeLegacyApplication(
    at url: URL,
    bundleIdentifier: String = "com.local.RemoteControlNetwork",
    executableName: String = "RemoteControlNetwork"
) throws {
    let macOSURL = url
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePlist(
        [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": executableName
        ],
        to: url.appendingPathComponent("Contents/Info.plist")
    )
    let executableURL = macOSURL.appendingPathComponent(executableName)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: executableURL.path
    )
}

private func makeManager(
    homeURL: URL,
    applicationPath: String? = nil,
    removeItem: ((URL) throws -> Void)? = nil,
    restoreItem: ((URL, Data, [FileAttributeKey: Any]) throws -> Void)? = nil,
    writeItem: ((URL, Data) throws -> Void)? = nil,
    setItemAttributes: ((URL, [FileAttributeKey: Any]) throws -> Void)? = nil,
    finalValidation: ((URL) -> Bool)? = nil
) -> LaunchAgentManager {
    LaunchAgentManager(
        fileManager: .default,
        agentsURL: homeURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
        applicationPath: applicationPath ??
            simulatedSystemApplications.appendingPathComponent("Gatebeam.app").path,
        userHomeURL: homeURL,
        userApplicationsURL: homeURL.appendingPathComponent("Applications", isDirectory: true),
        systemApplicationsURL: simulatedSystemApplications,
        removeItem: removeItem,
        restoreItem: restoreItem,
        writeItem: writeItem,
        setItemAttributes: setItemAttributes,
        finalValidation: finalValidation
    )
}

let fileManager = FileManager.default
let root = fileManager.temporaryDirectory
    .resolvingSymlinksInPath()
    .appendingPathComponent("gatebeam-launch-agent-tests-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }
let simulatedSystemApplications = root.appendingPathComponent("system/Applications", isDirectory: true)
try fileManager.createDirectory(at: simulatedSystemApplications, withIntermediateDirectories: true)

do {
    let home = root.appendingPathComponent("basic/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    let appPath = simulatedSystemApplications.appendingPathComponent("Gatebeam.app").path
    let manager = makeManager(homeURL: home, applicationPath: appPath)

    expectSuccess(manager.setEnabled(true), "enables login from the system Applications folder")
    let installed = plist(at: stableURL)
    expect(installed?["Label"] as? String == LaunchAgentManager.stableLabel, "uses the stable LaunchAgent label")
    expect(
        installed?["ProgramArguments"] as? [String] == ["/usr/bin/open", appPath],
        "writes the current Gatebeam path"
    )
    expect(installed?["RunAtLoad"] as? Bool == true, "enables RunAtLoad")

    try writePlist(
        [
            "Label": LaunchAgentManager.transitionalLabel,
            "ProgramArguments": ["/usr/bin/open", "/Applications/Gatebeam.app"]
        ],
        to: transitionalURL
    )
    expectSuccess(manager.setEnabled(true), "updates login from the system Applications folder")
    expect(!fileManager.fileExists(atPath: transitionalURL.path), "removes the owned transitional label")

    expectSuccess(manager.setEnabled(false), "disables login from the system Applications folder")
    expect(!fileManager.fileExists(atPath: stableURL.path), "disabling removes the owned stable LaunchAgent")

    try writePlist(["Label": "com.example.Unrelated"], to: stableURL)
    try writePlist(["Label": "com.example.Other"], to: transitionalURL)
    _ = manager.setEnabled(true)
    expect(plist(at: stableURL)?["Label"] as? String == "com.example.Unrelated", "does not overwrite a foreign stable plist")
    expect(plist(at: transitionalURL)?["Label"] as? String == "com.example.Other", "does not delete a foreign transitional plist")
    _ = manager.setEnabled(false)
    expect(fileManager.fileExists(atPath: stableURL.path), "does not uninstall a foreign stable plist")
    expect(fileManager.fileExists(atPath: transitionalURL.path), "does not uninstall a foreign transitional plist")

    try fileManager.removeItem(at: stableURL)
    try fileManager.removeItem(at: transitionalURL)
    try fileManager.createSymbolicLink(
        at: stableURL,
        withDestinationURL: root.appendingPathComponent("missing.plist")
    )
    _ = manager.setEnabled(true)
    let symlinkValues = try stableURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    expect(
        symlinkValues.isSymbolicLink == true,
        "does not replace a same-name symbolic link"
    )
}

do {
    let home = root.appendingPathComponent("user-applications/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let userApp = applications.appendingPathComponent("Gatebeam.app", isDirectory: true)
    try fileManager.createDirectory(at: userApp, withIntermediateDirectories: true)

    let manager = makeManager(homeURL: home, applicationPath: userApp.path)
    expectSuccess(manager.setEnabled(true), "enables login from the canonical user Applications folder")
    expect(
        plist(at: agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist"))?["ProgramArguments"]
            as? [String] == ["/usr/bin/open", userApp.path],
        "writes the canonical user Applications path"
    )
}

do {
    let home = root.appendingPathComponent("enable-delete-failure/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(
        [
            "Label": LaunchAgentManager.transitionalLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"]
        ],
        to: transitionalURL
    )
    let transitionalBefore = try Data(contentsOf: transitionalURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        }
    )

    expectUpdateFailure(
        manager.setEnabled(true),
        "enable reports a transitional LaunchAgent deletion failure"
    )
    expect(
        !fileManager.fileExists(atPath: stableURL.path),
        "failed enable rolls back the newly created stable LaunchAgent"
    )
    expect(
        (try? Data(contentsOf: transitionalURL)) == transitionalBefore,
        "failed enable preserves the transitional LaunchAgent"
    )
}

do {
    let home = root.appendingPathComponent("disable-delete-failure/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(
        [
            "Label": LaunchAgentManager.stableLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"],
            "RunAtLoad": true
        ],
        to: stableURL
    )
    try writePlist(
        [
            "Label": LaunchAgentManager.transitionalLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"],
            "RunAtLoad": true
        ],
        to: transitionalURL
    )
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: stableURL.path
    )
    let stableBefore = try Data(contentsOf: stableURL)
    let transitionalBefore = try Data(contentsOf: transitionalURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        }
    )

    expectUpdateFailure(
        manager.setEnabled(false),
        "disable reports a transitional LaunchAgent deletion failure"
    )
    expect(
        (try? Data(contentsOf: stableURL)) == stableBefore,
        "failed disable restores the stable LaunchAgent contents"
    )
    expect(
        (try? fileManager.attributesOfItem(atPath: stableURL.path)[.posixPermissions] as? NSNumber)?
            .intValue == 0o600,
        "failed disable restores the stable LaunchAgent mode"
    )
    expect(
        (try? Data(contentsOf: transitionalURL)) == transitionalBefore,
        "failed disable preserves the transitional LaunchAgent"
    )

    let recoveryManager = makeManager(homeURL: home)
    expectSuccess(
        recoveryManager.setEnabled(false),
        "disable succeeds after the deletion failure is removed"
    )
    expectSuccess(
        recoveryManager.setEnabled(false),
        "disable remains idempotent when managed plists are absent"
    )
}

do {
    let home = root.appendingPathComponent("enable-existing-rollback/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(
        [
            "Label": LaunchAgentManager.stableLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"],
            "RunAtLoad": false
        ],
        to: stableURL
    )
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: stableURL.path
    )
    let stableBefore = try Data(contentsOf: stableURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        }
    )

    expectUpdateFailure(
        manager.setEnabled(true),
        "enable reports cleanup failure when a stable LaunchAgent already exists"
    )
    expect(
        (try? Data(contentsOf: stableURL)) == stableBefore,
        "failed enable restores the previous stable LaunchAgent contents"
    )
    expect(
        (try? fileManager.attributesOfItem(atPath: stableURL.path)[.posixPermissions] as? NSNumber)?
            .intValue == 0o600,
        "failed enable restores the previous stable LaunchAgent mode"
    )
}

do {
    let home = root.appendingPathComponent("write-attributes-failure/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    try writePlist(
        [
            "Label": LaunchAgentManager.stableLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"],
            "RunAtLoad": false
        ],
        to: stableURL
    )
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: stableURL.path
    )
    let stableBefore = try Data(contentsOf: stableURL)
    let attributesBefore = try fileManager.attributesOfItem(atPath: stableURL.path)
    let manager = makeManager(
        homeURL: home,
        setItemAttributes: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
    )

    expectUpdateFailure(
        manager.setEnabled(true),
        "enable reports a chmod or chown failure after atomic write"
    )
    let attributesAfter = try fileManager.attributesOfItem(atPath: stableURL.path)
    expect(
        (try? Data(contentsOf: stableURL)) == stableBefore,
        "attribute-stage failure restores stable contents"
    )
    expect(
        (attributesAfter[.posixPermissions] as? NSNumber) ==
            (attributesBefore[.posixPermissions] as? NSNumber),
        "attribute-stage failure restores stable permissions"
    )
    expect(
        (attributesAfter[.ownerAccountID] as? NSNumber) ==
            (attributesBefore[.ownerAccountID] as? NSNumber),
        "attribute-stage failure restores stable ownership"
    )
    expect(
        (attributesAfter[.groupOwnerAccountID] as? NSNumber) ==
            (attributesBefore[.groupOwnerAccountID] as? NSNumber),
        "attribute-stage failure restores stable group ownership"
    )
}

do {
    let home = root.appendingPathComponent("final-validation-new-file/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let manager = makeManager(
        homeURL: home,
        finalValidation: { _ in false }
    )

    expectUpdateFailure(
        manager.setEnabled(true),
        "enable reports final path, decode, or ownership validation failure"
    )
    expect(
        !fileManager.fileExists(atPath: stableURL.path),
        "final validation failure removes a stable plist created by this transaction"
    )
}

do {
    let home = root.appendingPathComponent("final-validation-rollback-failure/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(["Label": LaunchAgentManager.stableLabel], to: stableURL)
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    let manager = makeManager(
        homeURL: home,
        restoreItem: { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        },
        finalValidation: { _ in false }
    )

    expectRecoveryFailure(
        manager.setEnabled(true),
        "enable distinguishes final-validation rollback failure"
    )
    expect(
        !fileManager.fileExists(atPath: stableURL.path),
        "failed final-validation rollback removes the mutated stable item"
    )
    expect(
        fileManager.fileExists(atPath: transitionalURL.path),
        "failed final-validation rollback preserves one recoverable launch item"
    )
}

do {
    let home = root.appendingPathComponent("stable-delete-failure/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    try writePlist(["Label": LaunchAgentManager.stableLabel], to: stableURL)
    let stableBefore = try Data(contentsOf: stableURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == stableURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        }
    )

    expectUpdateFailure(
        manager.setEnabled(false),
        "disable reports a stable LaunchAgent deletion failure"
    )
    expect(
        (try? Data(contentsOf: stableURL)) == stableBefore,
        "failed stable deletion leaves the managed LaunchAgent intact"
    )
}

do {
    let home = root.appendingPathComponent("foreign-stable-rollback/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(["Label": "com.example.Unrelated"], to: stableURL)
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    let stableBefore = try Data(contentsOf: stableURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        }
    )

    expectUpdateFailure(
        manager.setEnabled(false),
        "disable reports failure without treating a foreign stable plist as rollback state"
    )
    expect(
        (try? Data(contentsOf: stableURL)) == stableBefore,
        "failed disable never removes a foreign stable plist"
    )
}

do {
    let home = root.appendingPathComponent("disable-rollback-failure/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(["Label": LaunchAgentManager.stableLabel], to: stableURL)
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        },
        restoreItem: { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
    )

    expectRecoveryFailure(
        manager.setEnabled(false),
        "disable distinguishes a rollback failure from its original deletion failure"
    )
    expect(
        !fileManager.fileExists(atPath: stableURL.path),
        "failed disable rollback removes the mutated stable item to prevent duplicate launches"
    )
    expect(
        fileManager.fileExists(atPath: transitionalURL.path),
        "failed disable rollback preserves the transitional recovery item"
    )
}

func assertUnstableApplicationPath(_ applicationPath: String, scenario: String) throws {
    let fixture = root.appendingPathComponent("unstable-\(scenario)", isDirectory: true)
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)

    let legacyApp = applications.appendingPathComponent("Remote Control Network.app", isDirectory: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try makeLegacyApplication(at: legacyApp)
    try writePlist(
        [
            "Label": LaunchAgentManager.stableLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"],
            "RunAtLoad": true
        ],
        to: stableURL
    )
    try writePlist(
        [
            "Label": LaunchAgentManager.transitionalLabel,
            "ProgramArguments": ["/usr/bin/open", legacyApp.path],
            "RunAtLoad": true
        ],
        to: transitionalURL
    )
    let stableBefore = try Data(contentsOf: stableURL)
    let transitionalBefore = try Data(contentsOf: transitionalURL)
    let manager = makeManager(homeURL: home, applicationPath: applicationPath)

    expectUnstableLocation(
        manager.migrateLegacyUserState(),
        "\(scenario) does not run automatic migration"
    )
    expect(fileManager.fileExists(atPath: legacyApp.path), "\(scenario) preserves the legacy user app")
    expect((try? Data(contentsOf: stableURL)) == stableBefore, "\(scenario) preserves the stable LaunchAgent")
    expect(
        (try? Data(contentsOf: transitionalURL)) == transitionalBefore,
        "\(scenario) preserves the transitional LaunchAgent"
    )

    expectUnstableLocation(manager.setEnabled(true), "\(scenario) refuses to enable Start at Login")
    expectUnstableLocation(manager.setEnabled(false), "\(scenario) refuses to disable Start at Login")
    expect((try? Data(contentsOf: stableURL)) == stableBefore, "\(scenario) never rewrites the stable LaunchAgent")
    expect(
        (try? Data(contentsOf: transitionalURL)) == transitionalBefore,
        "\(scenario) never removes the transitional LaunchAgent"
    )
}

try assertUnstableApplicationPath(
    "/Volumes/Gatebeam/Gatebeam.app",
    scenario: "DMG volume"
)
try assertUnstableApplicationPath(
    root.appendingPathComponent("dist/Gatebeam.app").path,
    scenario: "dist path"
)
try assertUnstableApplicationPath(
    root.appendingPathComponent("tmp/Gatebeam.app").path,
    scenario: "temporary path"
)

do {
    let fixture = root.appendingPathComponent("application-symlink", isDirectory: true)
    let home = fixture.appendingPathComponent("home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    let outsideApp = fixture.appendingPathComponent("outside/Gatebeam.app", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outsideApp, withIntermediateDirectories: true)
    let appLink = applications.appendingPathComponent("Gatebeam.app", isDirectory: true)
    try fileManager.createSymbolicLink(at: appLink, withDestinationURL: outsideApp)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    try writePlist(
        [
            "Label": LaunchAgentManager.stableLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"]
        ],
        to: stableURL
    )
    let stableBefore = try Data(contentsOf: stableURL)
    let manager = makeManager(homeURL: home, applicationPath: appLink.path)

    expectUnstableLocation(
        manager.migrateLegacyUserState(),
        "a symbolic-link Gatebeam bundle does not migrate"
    )
    expectUnstableLocation(manager.setEnabled(true), "a symbolic-link Gatebeam bundle cannot enable login")
    expect((try? Data(contentsOf: stableURL)) == stableBefore, "a symbolic-link Gatebeam bundle preserves LaunchAgents")
    expect(fileManager.fileExists(atPath: outsideApp.path), "a symbolic-link Gatebeam bundle preserves its target")
}

do {
    let home = root.appendingPathComponent("migration/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)

    let legacyApp = applications.appendingPathComponent("Remote Control Network.app", isDirectory: true)
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    try makeLegacyApplication(at: legacyApp)
    try writePlist(
        [
            "Label": LaunchAgentManager.transitionalLabel,
            "ProgramArguments": ["/usr/bin/open", legacyApp.path],
            "RunAtLoad": true
        ],
        to: transitionalURL
    )

    let manager = makeManager(homeURL: home)
    expectSuccess(manager.migrateLegacyUserState(), "migrates verified per-user legacy state")
    expect(!fileManager.fileExists(atPath: legacyApp.path), "removes the verified per-user legacy app")
    expect(!fileManager.fileExists(atPath: transitionalURL.path), "removes the transitional LaunchAgent")
    expect(
        plist(at: stableURL)?["ProgramArguments"] as? [String] ==
            ["/usr/bin/open", simulatedSystemApplications.appendingPathComponent("Gatebeam.app").path],
        "rewrites the stable LaunchAgent to Gatebeam"
    )
    let attributes = try fileManager.attributesOfItem(atPath: stableURL.path)
    expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644, "writes LaunchAgent mode 0644")
    expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(), "keeps LaunchAgent owned by the current user")
    expect((attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getegid(), "keeps LaunchAgent in the current user's group")
    expectSuccess(manager.migrateLegacyUserState(), "per-user migration is idempotent")
}

do {
    let home = root.appendingPathComponent("migration-delete-failure/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(
        [
            "Label": LaunchAgentManager.stableLabel,
            "ProgramArguments": ["/usr/bin/open", "/previous/Gatebeam.app"],
            "RunAtLoad": false
        ],
        to: stableURL
    )
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: stableURL.path
    )
    let stableBefore = try Data(contentsOf: stableURL)
    let attributesBefore = try fileManager.attributesOfItem(atPath: stableURL.path)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        }
    )

    expectMigrationFailure(
        manager.migrateLegacyUserState(),
        "migration reports a transitional LaunchAgent deletion failure"
    )
    let attributesAfter = try fileManager.attributesOfItem(atPath: stableURL.path)
    expect(
        (try? Data(contentsOf: stableURL)) == stableBefore,
        "failed migration restores stable LaunchAgent contents"
    )
    expect(
        (attributesAfter[.posixPermissions] as? NSNumber) ==
            (attributesBefore[.posixPermissions] as? NSNumber),
        "failed migration restores stable LaunchAgent permissions"
    )
    expect(
        (attributesAfter[.ownerAccountID] as? NSNumber) ==
            (attributesBefore[.ownerAccountID] as? NSNumber),
        "failed migration restores stable LaunchAgent ownership"
    )
    expect(
        (attributesAfter[.groupOwnerAccountID] as? NSNumber) ==
            (attributesBefore[.groupOwnerAccountID] as? NSNumber),
        "failed migration restores stable LaunchAgent group ownership"
    )
    expect(
        fileManager.fileExists(atPath: transitionalURL.path),
        "failed migration preserves the transitional LaunchAgent"
    )
}

do {
    let home = root.appendingPathComponent("migration-rollback-failure/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let stableURL = agents.appendingPathComponent("\(LaunchAgentManager.stableLabel).plist")
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try writePlist(["Label": LaunchAgentManager.stableLabel], to: stableURL)
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    let manager = makeManager(
        homeURL: home,
        removeItem: { url in
            if url.standardizedFileURL.path == transitionalURL.standardizedFileURL.path {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.removeItem(at: url)
        },
        restoreItem: { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
    )

    expectRecoveryFailure(
        manager.migrateLegacyUserState(),
        "migration distinguishes a rollback failure from its deletion failure"
    )
    expect(
        !fileManager.fileExists(atPath: stableURL.path),
        "failed migration rollback removes stable to prevent duplicate launches"
    )
    expect(
        fileManager.fileExists(atPath: transitionalURL.path),
        "failed migration rollback preserves the transitional recovery item"
    )
}

do {
    let home = root.appendingPathComponent("applications-symlink/home", isDirectory: true)
    let outside = root.appendingPathComponent("applications-symlink/outside", isDirectory: true)
    try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideLegacy = outside.appendingPathComponent("Remote Control Network.app", isDirectory: true)
    try makeLegacyApplication(at: outsideLegacy)
    try fileManager.createSymbolicLink(
        at: home.appendingPathComponent("Applications"),
        withDestinationURL: outside
    )
    expectMigrationFailure(
        makeManager(homeURL: home).migrateLegacyUserState(),
        "rejects a symbolic-link Applications parent"
    )
    expect(fileManager.fileExists(atPath: outsideLegacy.path), "does not delete through an Applications symlink")
}

do {
    let home = root.appendingPathComponent("library-symlink/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let outsideLibrary = root.appendingPathComponent("library-symlink/outside-library", isDirectory: true)
    let outsideAgents = outsideLibrary.appendingPathComponent("LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outsideAgents, withIntermediateDirectories: true)
    let legacyApp = applications.appendingPathComponent("Remote Control Network.app", isDirectory: true)
    let transitionalURL = outsideAgents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try makeLegacyApplication(at: legacyApp)
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: transitionalURL)
    try fileManager.createSymbolicLink(
        at: home.appendingPathComponent("Library"),
        withDestinationURL: outsideLibrary
    )
    expectMigrationFailure(
        makeManager(homeURL: home).migrateLegacyUserState(),
        "rejects a symbolic-link Library parent"
    )
    expect(fileManager.fileExists(atPath: legacyApp.path), "preserves the legacy app when LaunchAgents is unsafe")
    expect(fileManager.fileExists(atPath: transitionalURL.path), "does not modify LaunchAgents through a Library symlink")
}

do {
    let home = root.appendingPathComponent("final-symlink/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    let outside = root.appendingPathComponent("final-symlink/outside", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideLegacy = outside.appendingPathComponent("Owned.app", isDirectory: true)
    try makeLegacyApplication(at: outsideLegacy)
    let legacyLink = applications.appendingPathComponent("Remote Control Network.app")
    try fileManager.createSymbolicLink(at: legacyLink, withDestinationURL: outsideLegacy)
    expectMigrationFailure(
        makeManager(homeURL: home).migrateLegacyUserState(),
        "rejects a final legacy-app symlink"
    )
    expect(fileManager.fileExists(atPath: outsideLegacy.path), "preserves a symlink target outside the home")

    try fileManager.removeItem(at: legacyLink)
    let outsidePlist = outside.appendingPathComponent("agent.plist")
    try writePlist(["Label": LaunchAgentManager.transitionalLabel], to: outsidePlist)
    let transitionalURL = agents.appendingPathComponent("\(LaunchAgentManager.transitionalLabel).plist")
    try fileManager.createSymbolicLink(at: transitionalURL, withDestinationURL: outsidePlist)
    expectMigrationFailure(
        makeManager(homeURL: home).migrateLegacyUserState(),
        "rejects a final LaunchAgent symlink"
    )
    expect(fileManager.fileExists(atPath: outsidePlist.path), "preserves a LaunchAgent symlink target")
}

do {
    let home = root.appendingPathComponent("forged/home", isDirectory: true)
    let applications = home.appendingPathComponent("Applications", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    let forgedApp = applications.appendingPathComponent("Remote Control Network.app", isDirectory: true)
    try makeLegacyApplication(at: forgedApp, bundleIdentifier: "com.example.Forged")
    expectMigrationFailure(
        makeManager(homeURL: home).migrateLegacyUserState(),
        "rejects a forged legacy Bundle ID"
    )
    expect(fileManager.fileExists(atPath: forgedApp.path), "preserves a forged legacy application")
}

do {
    let home = root.appendingPathComponent("escape/home", isDirectory: true)
    let agents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    let outsideApplications = root.appendingPathComponent("escape/outside-applications", isDirectory: true)
    try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outsideApplications, withIntermediateDirectories: true)
    let manager = LaunchAgentManager(
        fileManager: fileManager,
        agentsURL: agents,
        applicationPath: "/Applications/Gatebeam.app",
        userHomeURL: home,
        userApplicationsURL: outsideApplications
    )
    expectMigrationFailure(
        manager.migrateLegacyUserState(),
        "rejects a canonical path outside the user home"
    )
}

if failures > 0 {
    print("\(failures) upgrade test(s) failed")
    exit(1)
}
print("All LaunchAgent upgrade tests passed")
