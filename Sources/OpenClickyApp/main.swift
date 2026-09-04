import AppKit

/// Menu-bar agent entry point.
///
/// No storyboard and no main menu: the only surface is a floating panel.
/// `.accessory` keeps it out of the Dock and the app switcher, so summoning it never
/// disturbs the app the user is working in — which matters, because that app is
/// usually the one the agent has been asked to act on.
@MainActor
private enum Launcher {
    /// Held statically because `NSApplication.delegate` is a weak reference.
    static let delegate = AppDelegate()

    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
        exit(0)
    }
}

MainActor.assumeIsolated { Launcher.run() }
