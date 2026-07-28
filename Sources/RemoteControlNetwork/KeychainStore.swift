import Foundation
import LocalAuthentication
import Security

enum KeychainInteraction: Equatable {
    case background
    case userInitiated
}

enum KeychainQueryOperation: Equatable {
    case read
    case write
    case delete
}

struct KeychainQueryPolicy: Equatable {
    let interactionNotAllowed: Bool
    let failsAuthenticationUI: Bool
}

typealias KeychainQueryObserver = (
    _ operation: KeychainQueryOperation,
    _ interaction: KeychainInteraction,
    _ query: [String: Any]
) -> Void

enum KeychainAuthorizationOutcome: Equatable {
    case noSavedToken
    case authorized(token: String)
    case migratedLegacyToken(token: String)

    var token: String {
        switch self {
        case .noSavedToken:
            return ""
        case .authorized(let token), .migratedLegacyToken(let token):
            return token
        }
    }
}

struct KeychainOperationHandlers {
    private let scopedSet: (
        _ value: String,
        _ account: String,
        _ service: String,
        _ interaction: KeychainInteraction,
        _ refreshAccess: Bool
    ) throws -> Void
    private let scopedGet: (
        _ account: String,
        _ service: String,
        _ interaction: KeychainInteraction
    ) throws -> String?
    private let scopedDelete: (
        _ account: String,
        _ service: String,
        _ interaction: KeychainInteraction
    ) throws -> Void

    init(
        set: @escaping (_ value: String, _ account: String) throws -> Void,
        get: @escaping (_ account: String) throws -> String?,
        delete: @escaping (_ account: String) throws -> Void
    ) {
        self.scopedSet = { value, account, _, _, _ in
            try set(value, account)
        }
        self.scopedGet = { account, _, _ in
            try get(account)
        }
        self.scopedDelete = { account, _, _ in
            try delete(account)
        }
    }

    init(
        scopedSet: @escaping (
            _ value: String,
            _ account: String,
            _ service: String,
            _ interaction: KeychainInteraction,
            _ refreshAccess: Bool
        ) throws -> Void,
        scopedGet: @escaping (
            _ account: String,
            _ service: String,
            _ interaction: KeychainInteraction
        ) throws -> String?,
        scopedDelete: @escaping (
            _ account: String,
            _ service: String,
            _ interaction: KeychainInteraction
        ) throws -> Void
    ) {
        self.scopedSet = scopedSet
        self.scopedGet = scopedGet
        self.scopedDelete = scopedDelete
    }

    func set(
        _ value: String,
        account: String,
        service: String,
        interaction: KeychainInteraction,
        refreshAccess: Bool
    ) throws {
        try scopedSet(value, account, service, interaction, refreshAccess)
    }

    func get(
        account: String,
        service: String,
        interaction: KeychainInteraction
    ) throws -> String? {
        try scopedGet(account, service, interaction)
    }

    func delete(
        account: String,
        service: String,
        interaction: KeychainInteraction
    ) throws {
        try scopedDelete(account, service, interaction)
    }
}

final class KeychainStore {
    static let productionService = "io.github.naifuliang.gatebeam.cloudflare-token.v3"
    static let legacyServices = ["com.local.RemoteControlNetwork.secure-v2"]
    static let developerTeamInfoKey = "GatebeamDeveloperTeamIdentifier"

    private let service: String
    private let legacyServices: [String]
    private let useDataProtectionKeychain: Bool
    private let operationHandlers: KeychainOperationHandlers?
    private let queryObserver: KeychainQueryObserver?

    init(
        useDataProtectionKeychain: Bool = false,
        service: String? = nil,
        legacyServices: [String]? = nil,
        operationHandlers: KeychainOperationHandlers? = nil,
        queryObserver: KeychainQueryObserver? = nil
    ) {
        self.useDataProtectionKeychain = useDataProtectionKeychain
        self.operationHandlers = operationHandlers
        self.queryObserver = queryObserver
        self.service = service ?? (useDataProtectionKeychain
            ? "io.github.naifuliang.gatebeam.data-protection.v1"
            : Self.productionService)
        self.legacyServices = legacyServices
            ?? (service == nil && !useDataProtectionKeychain ? Self.legacyServices : [])
    }

    static func isolatedValidationStore(
        service: String = "io.github.naifuliang.gatebeam.ui-validation"
    ) -> KeychainStore {
        let lock = NSLock()
        var values: [String: String] = [:]
        let key: (String, String) -> String = { service, account in
            "\(service)\u{0}\(account)"
        }
        return KeychainStore(
            service: service,
            legacyServices: [],
            operationHandlers: KeychainOperationHandlers(
                scopedSet: { value, account, scopedService, _, _ in
                    lock.lock()
                    values[key(scopedService, account)] = value
                    lock.unlock()
                },
                scopedGet: { account, scopedService, _ in
                    lock.lock()
                    defer { lock.unlock() }
                    return values[key(scopedService, account)]
                },
                scopedDelete: { account, scopedService, _ in
                    lock.lock()
                    values.removeValue(forKey: key(scopedService, account))
                    lock.unlock()
                }
            )
        )
    }

    func set(
        _ value: String,
        account: String,
        interaction: KeychainInteraction = .userInitiated,
        refreshAccess: Bool = true
    ) throws {
        try set(
            value,
            account: account,
            service: service,
            interaction: interaction,
            refreshAccess: refreshAccess
        )
    }

    func get(
        account: String,
        interaction: KeychainInteraction = .background
    ) throws -> String? {
        try get(account: account, service: service, interaction: interaction)
    }

    @discardableResult
    func delete(
        account: String,
        interaction: KeychainInteraction = .userInitiated
    ) -> Result<Void, Error> {
        do {
            try delete(account: account, service: service, interaction: interaction)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func deleteChecked(
        account: String,
        interaction: KeychainInteraction = .userInitiated
    ) throws {
        try delete(account: account, interaction: interaction).get()
    }

    func authorizeCurrentOrMigrateLegacy(account: String) throws -> KeychainAuthorizationOutcome {
        if let current = try get(
            account: account,
            service: service,
            interaction: .userInitiated
        ) {
            try set(
                current,
                account: account,
                service: service,
                interaction: .userInitiated,
                refreshAccess: true
            )
            try verify(value: current, account: account)
            let removedLegacyItem = try removeLegacyItems(account: account)
            return removedLegacyItem
                ? .migratedLegacyToken(token: current)
                : .authorized(token: current)
        }

        for legacyService in legacyServices {
            guard let legacy = try get(
                account: account,
                service: legacyService,
                interaction: .userInitiated
            ) else {
                continue
            }

            try set(
                legacy,
                account: account,
                service: service,
                interaction: .userInitiated,
                refreshAccess: true
            )
            try verify(value: legacy, account: account)
            _ = try removeLegacyItems(account: account)
            return .migratedLegacyToken(token: legacy)
        }

        return .noSavedToken
    }

    private func removeLegacyItems(account: String) throws -> Bool {
        var removedAny = false
        for legacyService in legacyServices {
            guard try get(
                account: account,
                service: legacyService,
                interaction: .userInitiated
            ) != nil else {
                continue
            }
            do {
                try delete(
                    account: account,
                    service: legacyService,
                    interaction: .userInitiated
                )
                removedAny = true
            } catch {
                throw KeychainError.legacyCleanupFailed(
                    service: legacyService,
                    underlying: error.localizedDescription
                )
            }
        }
        return removedAny
    }

    private func verify(value: String, account: String) throws {
        guard try get(account: account, service: service, interaction: .background) == value else {
            throw KeychainError.verificationFailed
        }
    }

    private func set(
        _ value: String,
        account: String,
        service: String,
        interaction: KeychainInteraction,
        refreshAccess: Bool
    ) throws {
        let query = baseQuery(
            operation: .write,
            account: account,
            service: service,
            interaction: interaction
        )
        if let operationHandlers {
            try operationHandlers.set(
                value,
                account: account,
                service: service,
                interaction: interaction,
                refreshAccess: refreshAccess
            )
            return
        }

        let data = Data(value.utf8)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if useDataProtectionKeychain {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        } else if refreshAccess {
            attributes[kSecAttrAccess as String] = try currentApplicationAccess()
        }

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw KeychainError.status(operation: "update", code: status)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        if useDataProtectionKeychain {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        } else {
            addQuery[kSecAttrAccess as String] = try currentApplicationAccess()
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.status(operation: "add", code: addStatus)
        }
    }

    private func get(
        account: String,
        service: String,
        interaction: KeychainInteraction
    ) throws -> String? {
        var query = baseQuery(
            operation: .read,
            account: account,
            service: service,
            interaction: interaction
        )
        if let operationHandlers {
            return try operationHandlers.get(
                account: account,
                service: service,
                interaction: interaction
            )
        }

        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw KeychainError.status(operation: "read", code: status)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(
        account: String,
        service: String,
        interaction: KeychainInteraction
    ) throws {
        let query = baseQuery(
            operation: .delete,
            account: account,
            service: service,
            interaction: interaction
        )
        if let operationHandlers {
            try operationHandlers.delete(
                account: account,
                service: service,
                interaction: interaction
            )
            return
        }

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainError.status(operation: "delete", code: status)
    }

    private func baseQuery(
        operation: KeychainQueryOperation,
        account: String,
        service: String,
        interaction: KeychainInteraction
    ) -> [String: Any] {
        let policy = Self.queryPolicy(for: interaction)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = policy.interactionNotAllowed
        let query = Self.makeQueryDictionary(
            account: account,
            service: service,
            policy: policy,
            authenticationContext: authenticationContext,
            useDataProtectionKeychain: useDataProtectionKeychain
        )
        queryObserver?(operation, interaction, query)
        return query
    }

    static func queryPolicy(for interaction: KeychainInteraction) -> KeychainQueryPolicy {
        switch interaction {
        case .background:
            return KeychainQueryPolicy(
                interactionNotAllowed: true,
                failsAuthenticationUI: true
            )
        case .userInitiated:
            return KeychainQueryPolicy(
                interactionNotAllowed: false,
                failsAuthenticationUI: false
            )
        }
    }

    static func makeQueryDictionary(
        account: String,
        service: String,
        policy: KeychainQueryPolicy,
        authenticationContext: LAContext,
        useDataProtectionKeychain: Bool
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
        if policy.failsAuthenticationUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func currentApplicationAccess() throws -> SecAccess {
        let identity = try Self.currentSigningIdentity()
        guard let requirement = Self.validatedTrustedApplicationRequirement(identity) else {
            throw KeychainError.insecureCodeRequirement(identity.requirement)
        }
        guard requirement == identity.requirement else {
            throw KeychainError.insecureCodeRequirement(identity.requirement)
        }

        var trustedApplication: SecTrustedApplication?
        let trustedStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApplication)
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw KeychainError.status(
                operation: "create trusted application",
                code: trustedStatus
            )
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Gatebeam Cloudflare API token" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw KeychainError.status(operation: "create access control", code: accessStatus)
        }
        return access
    }

    struct SigningIdentity: Equatable {
        let requirement: String
        let signedBundleIdentifier: String?
        let expectedBundleIdentifier: String?
        let signedTeamIdentifier: String?
        let expectedTeamIdentifier: String?
        let currentCDHashes: [String]
        let hasHardenedRuntime: Bool
        let hasRuntimeVersion: Bool
        let hasSecureTimestamp: Bool
    }

    static func currentSigningIdentity() throws -> SigningIdentity {
        guard let executableURL = Bundle.main.executableURL else {
            throw KeychainError.status(
                operation: "locate signed executable",
                code: errSecInvalidItemRef
            )
        }

        var code: SecStaticCode?
        let codeStatus = SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            [],
            &code
        )
        guard codeStatus == errSecSuccess, let code else {
            throw KeychainError.status(operation: "inspect code signature", code: codeStatus)
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(
                rawValue: kSecCSSigningInformation | kSecCSRequirementInformation
            ),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let requirementValue = information[kSecCodeInfoDesignatedRequirement as String] else {
            throw KeychainError.status(
                operation: "read designated requirement",
                code: informationStatus
            )
        }
        let requirement = requirementValue as! SecRequirement

        var requirementText: CFString?
        let textStatus = SecRequirementCopyString(requirement, [], &requirementText)
        guard textStatus == errSecSuccess, let requirementText else {
            throw KeychainError.status(
                operation: "render designated requirement",
                code: textStatus
            )
        }

        let signedInfo = information[kSecCodeInfoPList as String] as? [String: Any]
        let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let runtimeVersion = information[kSecCodeInfoRuntimeVersion as String] as? NSNumber
        let currentCDHashes = (
            information[kSecCodeInfoCdHashes as String] as? [Data] ?? []
        ).map { data in
            data.map { String(format: "%02x", $0) }.joined()
        }

        return SigningIdentity(
            requirement: requirementText as String,
            signedBundleIdentifier: information[kSecCodeInfoIdentifier as String] as? String,
            expectedBundleIdentifier: signedInfo?["CFBundleIdentifier"] as? String,
            signedTeamIdentifier: information[kSecCodeInfoTeamIdentifier as String] as? String,
            expectedTeamIdentifier: signedInfo?[developerTeamInfoKey] as? String,
            currentCDHashes: currentCDHashes,
            hasHardenedRuntime: flags & 0x10000 != 0,
            hasRuntimeVersion: (runtimeVersion?.uint64Value ?? 0) != 0,
            hasSecureTimestamp: information[kSecCodeInfoTimestamp as String] != nil
        )
    }

    static func validatedTrustedApplicationRequirement(
        _ identity: SigningIdentity
    ) -> String? {
        guard identity.hasHardenedRuntime,
              identity.hasRuntimeVersion,
              let expectedBundleIdentifier = identity.expectedBundleIdentifier,
              !expectedBundleIdentifier.isEmpty,
              identity.signedBundleIdentifier == expectedBundleIdentifier else {
            return nil
        }

        let requirement = identity.requirement
            .replacingOccurrences(
                of: #"^\s*designated\s*=>\s*"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = requirement.lowercased()
        let exactBuildPattern =
            #"^\s*cdhash\s+h"[0-9a-f]{40,128}"(?:\s+or\s+cdhash\s+h"[0-9a-f]{40,128}")*\s*$"#
        let exactBuild = normalized.range(
            of: exactBuildPattern,
            options: .regularExpression
        ) != nil

        if identity.expectedTeamIdentifier == nil {
            let hashExpression = try? NSRegularExpression(
                pattern: #"cdhash\s+h"([0-9a-f]{40,128})""#,
                options: .caseInsensitive
            )
            let requirementRange = NSRange(
                normalized.startIndex..<normalized.endIndex,
                in: normalized
            )
            let requirementHashes = hashExpression?.matches(
                in: normalized,
                range: requirementRange
            ).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: normalized) else {
                    return nil
                }
                return String(normalized[range])
            } ?? []
            let currentHashes = Set(identity.currentCDHashes.map { $0.lowercased() })
            guard identity.signedTeamIdentifier == nil,
                  !identity.hasSecureTimestamp,
                  exactBuild,
                  !requirementHashes.isEmpty,
                  requirementHashes.allSatisfy({ currentHashes.contains($0) }) else {
                return nil
            }
            return requirement
        }

        guard let expectedTeamIdentifier = identity.expectedTeamIdentifier,
              !expectedTeamIdentifier.isEmpty,
              identity.signedTeamIdentifier == expectedTeamIdentifier,
              identity.hasSecureTimestamp else {
            return nil
        }

        let hasDeveloperIDCA =
            normalized.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists")
            || normalized.contains("certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */")
        let hasDeveloperIDLeaf =
            normalized.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
            || normalized.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */")
        let escapedBundleIdentifier = NSRegularExpression.escapedPattern(
            for: expectedBundleIdentifier.lowercased()
        )
        let escapedTeamIdentifier = NSRegularExpression.escapedPattern(
            for: expectedTeamIdentifier.lowercased()
        )
        let identifierPattern =
            #"(?:^|\s)identifier\s+"# + #""?"# + escapedBundleIdentifier + #""?(?:\s|$)"#
        let teamPattern =
            #"certificate\s+leaf\[subject\.ou\]\s*=\s*"# + #""?"#
                + escapedTeamIdentifier + #""?(?:\s|$)"#
        let hasExpectedIdentifier = normalized.range(
            of: identifierPattern,
            options: .regularExpression
        ) != nil
        let hasExpectedTeam = normalized.range(
            of: teamPattern,
            options: .regularExpression
        ) != nil
        let developerID = normalized.contains("anchor apple generic")
            && hasExpectedIdentifier
            && hasDeveloperIDCA
            && hasDeveloperIDLeaf
            && hasExpectedTeam
            && !normalized.contains(" or ")
        return developerID ? requirement : nil
    }
}

enum KeychainError: Error, LocalizedError {
    case status(operation: String, code: OSStatus)
    case verificationFailed
    case insecureCodeRequirement(String)
    case legacyCleanupFailed(service: String, underlying: String)

    var requiresUserAuthorization: Bool {
        if case .status(_, let code) = self {
            return code == errSecInteractionNotAllowed || code == errSecInteractionRequired
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .status(let operation, let code):
            let detail = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
            return "Keychain \(operation) failed: \(detail) (\(code))"
        case .verificationFailed:
            return "Keychain did not return the value that was just saved"
        case .insecureCodeRequirement:
            return "Gatebeam refused persistent token storage because this build has an insecure code-signing requirement"
        case .legacyCleanupFailed(let service, let underlying):
            return "The token was secured under the new Gatebeam identity, but legacy item \(service) could not be removed: \(underlying)"
        }
    }
}
