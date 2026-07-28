import AppKit

if CommandLine.arguments.contains("--signing-runtime-probe") {
    print("Gatebeam signing runtime probe ready")
    Thread.sleep(forTimeInterval: 2)
} else if CommandLine.arguments.contains("--signing-identity-probe") {
    do {
        let identity = try KeychainStore.currentSigningIdentity()
        guard KeychainStore.validatedTrustedApplicationRequirement(identity) != nil else {
            print("Gatebeam signing identity rejected")
            exit(1)
        }
        print("Gatebeam signing identity accepted")
    } catch {
        print("Gatebeam signing identity inspection failed: \(error.localizedDescription)")
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
