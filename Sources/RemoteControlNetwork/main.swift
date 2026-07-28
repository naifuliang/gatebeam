import AppKit

if CommandLine.arguments.contains("--signing-runtime-probe") {
    print("Gatebeam signing runtime probe ready")
    Thread.sleep(forTimeInterval: 2)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
