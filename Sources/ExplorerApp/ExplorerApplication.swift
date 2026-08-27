import AppKit

@MainActor
@main
struct ExplorerApplication {
    // `NSApplication.delegate` is not an ownership boundary. Keep the
    // application delegate alive explicitly for the entire process lifetime.
    private static let appDelegate = ExplorerAppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
