import AppKit
import Darwin

if CommandLine.arguments.contains("--keychain-self-test") {
    let account = "keychain-self-test-\(UUID().uuidString)"
    let value = UUID().uuidString
    let keychain = KeychainStore()
    do {
        try keychain.set(value, account: account)
        guard try keychain.get(account: account) == value else {
            throw KeychainError.verificationFailed
        }
        keychain.delete(account: account)
        print("Keychain self-test passed")
        exit(EXIT_SUCCESS)
    } catch {
        keychain.delete(account: account)
        fputs("Keychain self-test failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
