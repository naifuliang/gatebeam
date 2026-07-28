import Darwin
import Foundation

enum LaunchAgentManagerError: LocalizedError, Equatable {
    case unstableApplicationLocation
    case unableToUpdateLoginItem
    case unableToMigrateLoginItem
    case unableToRestoreLoginItem

    var errorDescription: String? {
        switch self {
        case .unstableApplicationLocation:
            return "Move Gatebeam to /Applications or your Applications folder, reopen it there, then enable Start at Login."
        case .unableToUpdateLoginItem:
            return "Gatebeam could not update Start at Login. Check the LaunchAgents folder permissions and try again."
        case .unableToMigrateLoginItem:
            return "Gatebeam could not migrate Start at Login. The previous login item was preserved; open Settings and try again."
        case .unableToRestoreLoginItem:
            return "Gatebeam could not restore Start at Login after an update failed. Automatic migration stopped to avoid duplicate launches. Check the LaunchAgents folder permissions, then turn Start at Login off and on again."
        }
    }
}

final class LaunchAgentManager {
    static let stableLabel = "com.local.RemoteControlNetwork.login"
    static let transitionalLabel = "io.github.naifuliang.gatebeam.login"

    private static let bundleIdentifier = "com.local.RemoteControlNetwork"
    private static let applicationName = "Gatebeam.app"
    private static let legacyApplicationName = "Remote Control Network.app"
    private static let legacyExecutableName = "RemoteControlNetwork"

    private let fileManager: FileManager
    private let agentsURL: URL?
    private let applicationPath: String
    private let userHomeURL: URL?
    private let userApplicationsURL: URL?
    private let systemApplicationsURL: URL
    private let removeItem: (URL) throws -> Void
    private let restoreItem: (URL, Data, [FileAttributeKey: Any]) throws -> Void
    private let writeItem: (URL, Data) throws -> Void
    private let setItemAttributes: (URL, [FileAttributeKey: Any]) throws -> Void
    private let finalValidation: ((URL) -> Bool)?

    private struct ManagedPlistSnapshot {
        let url: URL
        let data: Data
        let attributes: [FileAttributeKey: Any]
    }

    convenience init() {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        self.init(
            fileManager: fileManager,
            agentsURL: homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true),
            applicationPath: Bundle.main.bundlePath,
            userHomeURL: homeURL,
            userApplicationsURL: homeURL.appendingPathComponent("Applications", isDirectory: true),
            systemApplicationsURL: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }

    init(
        fileManager: FileManager,
        agentsURL: URL?,
        applicationPath: String,
        userHomeURL: URL? = nil,
        userApplicationsURL: URL? = nil,
        systemApplicationsURL: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        removeItem: ((URL) throws -> Void)? = nil,
        restoreItem: ((URL, Data, [FileAttributeKey: Any]) throws -> Void)? = nil,
        writeItem: ((URL, Data) throws -> Void)? = nil,
        setItemAttributes: ((URL, [FileAttributeKey: Any]) throws -> Void)? = nil,
        finalValidation: ((URL) -> Bool)? = nil
    ) {
        self.fileManager = fileManager
        self.agentsURL = agentsURL?.standardizedFileURL
        self.applicationPath = applicationPath
        self.userHomeURL = userHomeURL?.standardizedFileURL
        self.userApplicationsURL = userApplicationsURL?.standardizedFileURL
        self.systemApplicationsURL = systemApplicationsURL.standardizedFileURL
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
        self.restoreItem = restoreItem ?? { url, data, attributes in
            try data.write(to: url, options: .atomic)
            if !attributes.isEmpty {
                try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
            }
        }
        self.writeItem = writeItem ?? { url, data in
            try data.write(to: url, options: .atomic)
        }
        self.setItemAttributes = setItemAttributes ?? { url, attributes in
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
        self.finalValidation = finalValidation
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Result<Void, LaunchAgentManagerError> {
        guard isRunningFromStableInstallation() else {
            return .failure(.unstableApplicationLocation)
        }

        if enabled {
            return install()
        } else {
            return uninstall()
        }
    }

    @discardableResult
    func migrateLegacyUserState() -> Result<Void, LaunchAgentManagerError> {
        guard isRunningFromStableInstallation() else {
            return .failure(.unstableApplicationLocation)
        }
        guard geteuid() != 0 else {
            return .failure(.unableToMigrateLoginItem)
        }
        guard
            let homeURL = canonicalUserHome(),
            let applicationsURL = userApplicationsURL,
            let agentsURL
        else {
            return .success(())
        }

        let expectedApplicationsURL = homeURL.appendingPathComponent("Applications", isDirectory: true)
        let expectedAgentsURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        guard
            applicationsURL.standardizedFileURL.path == expectedApplicationsURL.path,
            agentsURL.standardizedFileURL.path == expectedAgentsURL.path,
            hasNoSymbolicLinkComponents(from: homeURL, through: applicationsURL, allowMissingLeaf: true),
            hasNoSymbolicLinkComponents(from: homeURL, through: agentsURL, allowMissingLeaf: true)
        else {
            return .failure(.unableToMigrateLoginItem)
        }

        switch migrateManagedLaunchAgentIfNeeded(at: agentsURL) {
        case .success:
            break
        case .failure(let error):
            return .failure(error)
        }

        let legacyAppURL = applicationsURL.appendingPathComponent(Self.legacyApplicationName, isDirectory: true)
        guard pathExistsIncludingSymbolicLink(legacyAppURL) else {
            return .success(())
        }
        guard
            hasNoSymbolicLinkComponents(from: homeURL, through: legacyAppURL, allowMissingLeaf: false),
            isVerifiedLegacyApplication(at: legacyAppURL)
        else {
            return .failure(.unableToMigrateLoginItem)
        }

        do {
            try removeItem(legacyAppURL)
            return .success(())
        } catch {
            return .failure(.unableToMigrateLoginItem)
        }
    }

    private func install() -> Result<Void, LaunchAgentManagerError> {
        guard let agentsURL, prepareAgentsDirectoryForWrite(agentsURL) else {
            return .failure(.unableToUpdateLoginItem)
        }

        let plistURL = agentsURL.appendingPathComponent("\(Self.stableLabel).plist")
        guard canWriteManagedPlist(at: plistURL, expectedLabel: Self.stableLabel) else {
            return .failure(.unableToUpdateLoginItem)
        }
        let stableExists = pathExistsIncludingSymbolicLink(plistURL)
        let stableSnapshot = managedPlistSnapshot(
            at: plistURL,
            expectedLabel: Self.stableLabel
        )
        guard !stableExists || stableSnapshot != nil else {
            return .failure(.unableToUpdateLoginItem)
        }
        guard writeLaunchAgent(at: plistURL) else {
            return compensateStableMutation(
                snapshot: stableSnapshot,
                at: plistURL,
                primaryError: .unableToUpdateLoginItem
            )
        }

        guard removeManagedPlist(
            at: agentsURL.appendingPathComponent("\(Self.transitionalLabel).plist"),
            expectedLabel: Self.transitionalLabel
        ) else {
            return compensateStableMutation(
                snapshot: stableSnapshot,
                at: plistURL,
                primaryError: .unableToUpdateLoginItem
            )
        }
        return .success(())
    }

    private func uninstall() -> Result<Void, LaunchAgentManagerError> {
        guard let agentsURL else {
            return .failure(.unableToUpdateLoginItem)
        }
        guard pathExistsIncludingSymbolicLink(agentsURL) else {
            return .success(())
        }
        guard isSafeExistingAgentsDirectory(agentsURL) else {
            return .failure(.unableToUpdateLoginItem)
        }

        let stableURL = agentsURL.appendingPathComponent("\(Self.stableLabel).plist")
        let transitionalURL = agentsURL.appendingPathComponent("\(Self.transitionalLabel).plist")
        let stableSnapshot = managedPlistSnapshot(
            at: stableURL,
            expectedLabel: Self.stableLabel
        )
        guard !pathExistsIncludingSymbolicLink(stableURL) || stableSnapshot != nil else {
            return .failure(.unableToUpdateLoginItem)
        }
        guard removeManagedPlist(at: stableURL, expectedLabel: Self.stableLabel) else {
            return .failure(.unableToUpdateLoginItem)
        }
        guard removeManagedPlist(
            at: transitionalURL,
            expectedLabel: Self.transitionalLabel
        ) else {
            if let stableSnapshot {
                guard restoreManagedPlist(stableSnapshot) else {
                    _ = removeTransactionStablePlist(at: stableURL)
                    return .failure(.unableToRestoreLoginItem)
                }
            }
            return .failure(.unableToUpdateLoginItem)
        }
        return .success(())
    }

    private func isRunningFromStableInstallation() -> Bool {
        let applicationURL = URL(
            fileURLWithPath: applicationPath,
            isDirectory: true
        ).standardizedFileURL
        guard applicationURL.lastPathComponent == Self.applicationName else {
            return false
        }

        let expectedSystemURL = systemApplicationsURL
            .appendingPathComponent(Self.applicationName, isDirectory: true)
            .standardizedFileURL
        if applicationURL.path == expectedSystemURL.path {
            return hasNoSymbolicLinkComponents(
                from: systemApplicationsURL,
                through: applicationURL,
                allowMissingLeaf: true
            )
        }

        guard
            let homeURL = canonicalUserHome(),
            let applicationsURL = userApplicationsURL
        else {
            return false
        }
        let expectedApplicationsURL = homeURL
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
        let expectedUserURL = expectedApplicationsURL
            .appendingPathComponent(Self.applicationName, isDirectory: true)
            .standardizedFileURL
        guard
            applicationsURL.standardizedFileURL.path == expectedApplicationsURL.path,
            applicationURL.path == expectedUserURL.path
        else {
            return false
        }
        return hasNoSymbolicLinkComponents(
            from: homeURL,
            through: applicationURL,
            allowMissingLeaf: true
        )
    }

    private func migrateManagedLaunchAgentIfNeeded(
        at agentsURL: URL
    ) -> Result<Void, LaunchAgentManagerError> {
        guard pathExistsIncludingSymbolicLink(agentsURL) else {
            return .success(())
        }
        guard isSafeExistingAgentsDirectory(agentsURL) else {
            return .failure(.unableToMigrateLoginItem)
        }

        let stableURL = agentsURL.appendingPathComponent("\(Self.stableLabel).plist")
        let transitionalURL = agentsURL.appendingPathComponent("\(Self.transitionalLabel).plist")
        let stableExists = pathExistsIncludingSymbolicLink(stableURL)
        let transitionalExists = pathExistsIncludingSymbolicLink(transitionalURL)

        if stableExists && managedLabel(at: stableURL) != Self.stableLabel {
            return .failure(.unableToMigrateLoginItem)
        }
        if transitionalExists && managedLabel(at: transitionalURL) != Self.transitionalLabel {
            return .failure(.unableToMigrateLoginItem)
        }
        guard stableExists || transitionalExists else {
            return .success(())
        }
        let stableSnapshot = managedPlistSnapshot(
            at: stableURL,
            expectedLabel: Self.stableLabel
        )
        guard !stableExists || stableSnapshot != nil else {
            return .failure(.unableToMigrateLoginItem)
        }
        guard writeLaunchAgent(at: stableURL) else {
            return compensateStableMutation(
                snapshot: stableSnapshot,
                at: stableURL,
                primaryError: .unableToMigrateLoginItem
            )
        }
        if transitionalExists && !removeManagedPlist(
            at: transitionalURL,
            expectedLabel: Self.transitionalLabel
        ) {
            return compensateStableMutation(
                snapshot: stableSnapshot,
                at: stableURL,
                primaryError: .unableToMigrateLoginItem
            )
        }
        return .success(())
    }

    private func writeLaunchAgent(at plistURL: URL) -> Bool {
        let plist: [String: Any] = [
            "Label": Self.stableLabel,
            "ProgramArguments": ["/usr/bin/open", applicationPath],
            "RunAtLoad": true
        ]
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        else {
            return false
        }

        do {
            try writeItem(plistURL, data)
            try setItemAttributes(
                plistURL,
                [
                    .posixPermissions: NSNumber(value: Int16(0o644)),
                    .ownerAccountID: NSNumber(value: geteuid()),
                    .groupOwnerAccountID: NSNumber(value: getegid())
                ]
            )
            return validateWrittenLaunchAgent(at: plistURL)
        } catch {
            return false
        }
    }

    private func validateWrittenLaunchAgent(at url: URL) -> Bool {
        guard
            let agentsURL,
            url.standardizedFileURL.path == agentsURL
                .appendingPathComponent("\(Self.stableLabel).plist")
                .standardizedFileURL.path,
            isSafeExistingAgentsDirectory(agentsURL),
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let attributes = try? fileManager.attributesOfItem(atPath: url.path),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
            (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value == getegid(),
            managedLabel(at: url) == Self.stableLabel
        else {
            return false
        }
        return finalValidation?(url) ?? true
    }

    private func prepareAgentsDirectoryForWrite(_ agentsURL: URL) -> Bool {
        if pathExistsIncludingSymbolicLink(agentsURL) {
            return isSafeExistingAgentsDirectory(agentsURL)
        }

        if let homeURL = canonicalUserHome() {
            let expectedURL = homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true)
            guard
                agentsURL.standardizedFileURL.path == expectedURL.path,
                hasNoSymbolicLinkComponents(
                    from: homeURL,
                    through: agentsURL.deletingLastPathComponent(),
                    allowMissingLeaf: false
                )
            else {
                return false
            }
        } else if isSymbolicLink(agentsURL.deletingLastPathComponent()) {
            return false
        }

        do {
            try fileManager.createDirectory(at: agentsURL, withIntermediateDirectories: false)
            return isSafeExistingAgentsDirectory(agentsURL)
        } catch {
            return false
        }
    }

    private func isSafeExistingAgentsDirectory(_ agentsURL: URL) -> Bool {
        guard
            let values = try? agentsURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            return false
        }

        if let homeURL = canonicalUserHome() {
            let expectedURL = homeURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true)
            return agentsURL.standardizedFileURL.path == expectedURL.path &&
                hasNoSymbolicLinkComponents(from: homeURL, through: agentsURL, allowMissingLeaf: false)
        }
        return !isSymbolicLink(agentsURL.deletingLastPathComponent())
    }

    private func canWriteManagedPlist(at url: URL, expectedLabel: String) -> Bool {
        guard pathExistsIncludingSymbolicLink(url) else {
            return true
        }
        return managedLabel(at: url) == expectedLabel
    }

    private func removeManagedPlist(at url: URL, expectedLabel: String) -> Bool {
        guard pathExistsIncludingSymbolicLink(url) else {
            return true
        }
        guard managedLabel(at: url) == expectedLabel else {
            return true
        }
        do {
            try removeItem(url)
            return !pathExistsIncludingSymbolicLink(url)
        } catch {
            return false
        }
    }

    private func managedPlistSnapshot(
        at url: URL,
        expectedLabel: String
    ) -> ManagedPlistSnapshot? {
        guard
            managedLabel(at: url) == expectedLabel,
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        guard
            let sourceAttributes = try? fileManager.attributesOfItem(atPath: url.path),
            let permissions = sourceAttributes[.posixPermissions],
            let owner = sourceAttributes[.ownerAccountID],
            let group = sourceAttributes[.groupOwnerAccountID]
        else {
            return nil
        }
        return ManagedPlistSnapshot(
            url: url,
            data: data,
            attributes: [
                .posixPermissions: permissions,
                .ownerAccountID: owner,
                .groupOwnerAccountID: group
            ]
        )
    }

    private func restoreManagedPlist(_ snapshot: ManagedPlistSnapshot) -> Bool {
        do {
            try restoreItem(snapshot.url, snapshot.data, snapshot.attributes)
            return matchesManagedPlistSnapshot(snapshot)
        } catch {
            return false
        }
    }

    private func matchesManagedPlistSnapshot(_ snapshot: ManagedPlistSnapshot) -> Bool {
        guard
            !isSymbolicLink(snapshot.url),
            (try? Data(contentsOf: snapshot.url)) == snapshot.data,
            let current = try? fileManager.attributesOfItem(atPath: snapshot.url.path)
        else {
            return false
        }
        for key in [
            FileAttributeKey.posixPermissions,
            .ownerAccountID,
            .groupOwnerAccountID
        ] {
            guard
                let expected = snapshot.attributes[key] as? NSNumber,
                let actual = current[key] as? NSNumber,
                expected == actual
            else {
                return false
            }
        }
        return managedLabel(at: snapshot.url) == Self.stableLabel
    }

    private func compensateStableMutation(
        snapshot: ManagedPlistSnapshot?,
        at stableURL: URL,
        primaryError: LaunchAgentManagerError
    ) -> Result<Void, LaunchAgentManagerError> {
        let restored: Bool
        if let snapshot {
            restored = matchesManagedPlistSnapshot(snapshot) ||
                restoreManagedPlist(snapshot)
        } else {
            restored = removeTransactionStablePlist(at: stableURL)
        }
        guard !restored else {
            return .failure(primaryError)
        }

        // Keep the transitional item as the sole launch path whenever restoration fails.
        _ = removeTransactionStablePlist(at: stableURL)
        return .failure(.unableToRestoreLoginItem)
    }

    private func removeTransactionStablePlist(at url: URL) -> Bool {
        guard pathExistsIncludingSymbolicLink(url) else {
            return true
        }
        guard
            let agentsURL,
            url.standardizedFileURL.path == agentsURL
                .appendingPathComponent("\(Self.stableLabel).plist")
                .standardizedFileURL.path,
            isSafeExistingAgentsDirectory(agentsURL),
            !isSymbolicLink(url)
        else {
            return false
        }
        do {
            try removeItem(url)
            return !pathExistsIncludingSymbolicLink(url)
        } catch {
            return false
        }
    }

    private func managedLabel(at url: URL) -> String? {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else {
            return nil
        }
        return dictionary["Label"] as? String
    }

    private func canonicalUserHome() -> URL? {
        guard let userHomeURL else {
            return nil
        }
        guard !isSymbolicLink(userHomeURL) else {
            return nil
        }
        return userHomeURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func hasNoSymbolicLinkComponents(
        from baseURL: URL,
        through targetURL: URL,
        allowMissingLeaf: Bool
    ) -> Bool {
        let base = baseURL.standardizedFileURL
        let target = targetURL.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            return false
        }
        guard !isSymbolicLink(base) else {
            return false
        }

        let relativePath = String(target.path.dropFirst(base.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else {
            return true
        }

        let components = relativePath.split(separator: "/").map(String.init)
        var currentURL = base
        for (index, component) in components.enumerated() {
            currentURL.appendPathComponent(component)
            if isSymbolicLink(currentURL) {
                return false
            }
            if !fileManager.fileExists(atPath: currentURL.path) {
                return allowMissingLeaf && index == components.count - 1
            }
        }
        return true
    }

    private func isVerifiedLegacyApplication(at appURL: URL) -> Bool {
        guard
            let appValues = try? appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            appValues.isDirectory == true,
            appValues.isSymbolicLink != true
        else {
            return false
        }

        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        guard
            !isSymbolicLink(contentsURL),
            !isSymbolicLink(plistURL),
            let data = try? Data(contentsOf: plistURL),
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let plist = value as? [String: Any],
            plist["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
            plist["CFBundleExecutable"] as? String == Self.legacyExecutableName
        else {
            return false
        }

        let executableURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(Self.legacyExecutableName)
        guard
            let executableValues = try? executableURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            executableValues.isRegularFile == true,
            executableValues.isSymbolicLink != true,
            fileManager.isExecutableFile(atPath: executableURL.path)
        else {
            return false
        }
        return true
    }

    private func pathExistsIncludingSymbolicLink(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
