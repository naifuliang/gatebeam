import Foundation
import LocalAuthentication
import Security

enum ProbeFailure: Error, LocalizedError {
    case usage
    case status(operation: String, code: OSStatus)
    case missingData

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: KeychainACLProbe <create|read|delete> <keychain-path> <service> <persistent-ref-path>"
        case .status(let operation, let code):
            let detail = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
            return "\(operation): \(detail) (\(code))"
        case .missingData:
            return "Keychain read returned no data"
        }
    }
}

#if TRUSTED_BUILD
let buildMarker = "trusted-exact-build"
#else
let buildMarker = "spoofed-same-identifier-build"
#endif

let account = "cloudflare-api-token"
let token = "keychain-acl-fixture-token"

func checked(_ status: OSStatus, operation: String) throws {
    guard status == errSecSuccess else {
        throw ProbeFailure.status(operation: operation, code: status)
    }
}

func keychain(at path: String) throws -> SecKeychain {
    var keychain: SecKeychain?
    try checked(
        SecKeychainOpen(path, &keychain),
        operation: "open test keychain"
    )
    guard let keychain else {
        throw ProbeFailure.status(operation: "open test keychain", code: errSecNoSuchKeychain)
    }
    return keychain
}

func query(
    keychain: SecKeychain,
    service: String,
    interactionAllowed: Bool
) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = !interactionAllowed
    return [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecUseKeychain as String: keychain,
        kSecUseAuthenticationContext as String: context
    ]
}

func create(keychain: SecKeychain, service: String) throws {
    var access: SecAccess?
    try checked(
        SecAccessCreate(
            "Gatebeam ACL fixture" as CFString,
            nil,
            &access
        ),
        operation: "create exact-build ACL"
    )
    guard let access else {
        throw ProbeFailure.status(operation: "create exact-build ACL", code: errSecInvalidItemRef)
    }

    var addQuery = query(
        keychain: keychain,
        service: service,
        interactionAllowed: true
    )
    addQuery[kSecValueData as String] = Data(token.utf8)
    addQuery[kSecAttrAccess as String] = access
    addQuery[kSecReturnPersistentRef as String] = true
    var result: CFTypeRef?
    try checked(
        SecItemAdd(addQuery as CFDictionary, &result),
        operation: "add ACL fixture"
    )
    guard let persistentReference = result as? Data else {
        throw ProbeFailure.missingData
    }
    try persistentReference.write(
        to: URL(fileURLWithPath: CommandLine.arguments[4]),
        options: [.atomic]
    )
}

func persistentReferenceQuery(interactionAllowed: Bool) throws -> [String: Any] {
    let persistentReference = try Data(
        contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])
    )
    let context = LAContext()
    context.interactionNotAllowed = !interactionAllowed
    return [
        kSecValuePersistentRef as String: persistentReference,
        kSecUseAuthenticationContext as String: context
    ]
}

func read() throws -> String {
    var readQuery = try persistentReferenceQuery(interactionAllowed: false)
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    try checked(
        SecItemCopyMatching(readQuery as CFDictionary, &result),
        operation: "read ACL fixture"
    )
    guard let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
        throw ProbeFailure.missingData
    }
    return value
}

func delete() throws {
    let status = SecItemDelete(
        try persistentReferenceQuery(interactionAllowed: true) as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw ProbeFailure.status(operation: "delete ACL fixture", code: status)
    }
}

do {
    guard CommandLine.arguments.count == 5 else {
        throw ProbeFailure.usage
    }
    let operation = CommandLine.arguments[1]
    let testKeychain = try keychain(at: CommandLine.arguments[2])
    let service = CommandLine.arguments[3]

    switch operation {
    case "create":
        try create(keychain: testKeychain, service: service)
        print("\(buildMarker):created")
    case "read":
        print("\(buildMarker):\(try read())")
    case "delete":
        try delete()
        print("\(buildMarker):deleted")
    default:
        throw ProbeFailure.usage
    }
} catch {
    fputs("\(buildMarker):\(error.localizedDescription)\n", stderr)
    exit(23)
}
