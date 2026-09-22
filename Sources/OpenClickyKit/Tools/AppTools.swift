import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Tier 0 — bring an application to the front, launching it if it is not running.
///
/// The model had no way to do this except prose. "Open Spotify" became
/// `shell: open -a Spotify` — a real recorded run — which is a shell string standing in
/// for a structured call, and it is worse than it looks in three ways: the risk
/// classifier has to read the command back out of English, `open -a` resolves a *name*
/// through LaunchServices rather than naming a thing, and the run has no idea afterwards
/// whether the app actually came forward.
///
/// **Tier 0, and that is not a technicality.** `NSWorkspace.openApplication` needs no TCC
/// grant at all — not Accessibility, not Automation, not Screen Recording. Placing it at
/// tier 1 alongside AppleScript would let `reachableTier` cap it out on a machine with no
/// Automation grant, which is precisely backwards: this is the capability that still
/// works when nothing else does, and the ladder's rule is the lowest tier that can do the
/// job.
///
/// **Addressed by bundle identifier, and only one the catalogue knows.** Not for want of
/// a safe way to run `open` — `Subprocess` takes argument arrays and never a shell — but
/// because `open -a Safari` asks LaunchServices to *resolve a name*, and a fuzzy resolver
/// in the middle means the argument is no longer the identity of what launches. `.focus`
/// is only defensible because what was activated is what was enumerated, so the URL comes
/// off the catalogue entry and goes straight to the workspace.
public struct ActivateAppTool: Tool {
    public let name = "activate_app"
    public let tier = Tier.shell

    public let description = """
    Bring an application to the front, launching it first if it is not running. \
    Takes a bundle identifier, e.g. com.apple.Safari.

    Prefer this over `shell: open -a …` and over AppleScript `activate`. It needs no \
    permissions, it names the app rather than asking macOS to guess from a name, and it \
    reports whether the app actually came forward instead of leaving you to check.

    Use it before anything that types, clicks or reads a window: acting on an app that \
    is not in front is how keystrokes land somewhere else. If you do not know the \
    identifier, `ax_capture` names the frontmost app and `app_script` can list what is \
    running.
    """

    public var inputSchema: JSONValue {
        .schema([
            "bundle_identifier": .string(describing:
                "The app's bundle identifier, e.g. com.apple.Safari or com.google.Chrome."),
        ], required: ["bundle_identifier"])
    }

    /// The apps this machine has, read at classification time rather than held.
    ///
    /// Injected as a closure for the reason every seam in this project is: a test must
    /// be able to say what is installed. Synchronous, because `risk(for:)` is.
    public let catalogue: @Sendable () -> AppCatalogue
    /// Our own bundles, so the agent cannot be asked to switch to itself.
    public let selfBundleIDs: [String]
    /// Who is in front, so the result can say whether that changed.
    public let frontmost: @Sendable () -> String?
    /// How an app is actually brought forward.
    ///
    /// A seam, like `ScriptRunning` and `frontmostBundleIdentifier` elsewhere: every
    /// rule in `run` below — refusing an app the catalogue does not have, refusing our
    /// own, reporting honestly when the app does not arrive — is decidable without a
    /// window server, and a rule that can only be checked by launching Safari is a rule
    /// that will be checked once.
    public let activate: @Sendable (AppCatalogue.Entry) async throws -> Void

    public init(
        selfBundleIDs: [String] = [],
        catalogue: (@Sendable () -> AppCatalogue)? = nil,
        frontmost: (@Sendable () -> String?)? = nil,
        activate: (@Sendable (AppCatalogue.Entry) async throws -> Void)? = nil
    ) {
        let identifiers = Set(selfBundleIDs)
        self.selfBundleIDs = selfBundleIDs
        self.catalogue = catalogue ?? { AppCatalogue.current(selfBundleIDs: identifiers) }
        self.frontmost = frontmost ?? ActivateAppTool.systemFrontmost
        self.activate = activate ?? ActivateAppTool.bringToFront
    }

    /// `.focus` only for an app this machine actually has.
    ///
    /// The three lines that carry the whole safety argument. `FocusChange.activate` takes
    /// a catalogue entry, so reaching this classification is *proof* that the identifier
    /// was matched against an enumeration of the disk — and an identifier that was not
    /// falls through to `.write`, which prompts in `.ask` and is refused in `.readOnly`
    /// like any other unexplained change.
    ///
    /// It never throws and never blocks on the disk: a cold catalogue answers empty, so
    /// the unknown-app path is taken and the call is gated more strictly rather than
    /// stalling the loop on a filesystem scan.
    public func risk(for input: JSONValue) -> Risk {
        guard let identifier = input["bundle_identifier"]?.stringValue,
              let entry = catalogue().entry(bundleIdentifier: identifier)
        else {
            return .write(summary: "activate an application this Mac does not list")
        }
        return .focus(.activate(entry))
    }

    public func run(_ input: JSONValue) async throws -> ToolOutput {
        let identifier = try input.string("bundle_identifier")
        guard !selfBundleIDs.contains(identifier) else {
            return .failure("""
                \(identifier) is this agent's own application. Switching to it would take \
                the screen away from the work, not toward it.
                """)
        }
        guard let entry = catalogue().entry(bundleIdentifier: identifier) else {
            return .failure("""
                No application with the identifier \(identifier) is installed or running \
                on this Mac. Check the identifier — `ax_capture` names the frontmost app, \
                and `app_script` can list what is running.
                """)
        }

        let before = frontmost()
        do {
            try await activate(entry)
        } catch {
            return .failure("Could not open \(entry.name): \(error.localizedDescription)")
        }

        // Polled rather than assumed. macOS activation is cooperative and can be
        // refused or deferred — an app that is launching has no window for a moment,
        // and a background process asking for the front is not always granted it. The
        // one thing this must not do is report a change it did not observe.
        let arrived = await Self.waitForFront(entry.bundleIdentifier, frontmost: frontmost)
        guard arrived else {
            return ToolOutput(
                content: [.text("""
                    Asked macOS to bring \(entry.name) to the front, but it is still not \
                    frontmost\(before.map { " (\($0) is)" } ?? ""). It may still be \
                    launching, or macOS may have refused the activation. Check before \
                    typing or clicking into it.
                    """)],
                changeVerdict: .unchanged
            )
        }
        return ToolOutput(
            content: [.text("\(entry.name) is now frontmost.")], changeVerdict: .changed
        )
    }

    // MARK: - The workspace

    /// How long to wait for an app to come forward.
    ///
    /// A running app switches in well under a second; a cold launch of something large
    /// can take longer than anyone wants to block a turn for. This is the point at which
    /// saying "it has not come forward yet" is more useful than continuing to wait.
    static let settle: TimeInterval = 2.5
    static let poll: TimeInterval = 0.1

    static let bringToFront: @Sendable (AppCatalogue.Entry) async throws -> Void = { entry in
        #if canImport(AppKit)
        // Already running: activating the existing instance is both cheaper and correct.
        // Going through `openApplication` for a running app risks a second instance on
        // apps that permit one, which is not what "bring it to the front" means.
        if let running = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == entry.bundleIdentifier }
        ) {
            running.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Pinned rather than defaulted. Each of these is a way for "bring this app
        // forward" to become something else: a second copy of an app that was already
        // open, a document handler invoked with arguments, an entry in the user's
        // Recents that they did not ask for.
        configuration.createsNewApplicationInstance = false
        configuration.arguments = []
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        _ = try await NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
        #endif
    }

    static func waitForFront(
        _ identifier: String, frontmost: @Sendable () -> String?
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            if frontmost() == identifier { return true }
            try? await Task.sleep(for: .seconds(poll))
        }
        return frontmost() == identifier
    }

    static let systemFrontmost: @Sendable () -> String? = {
        #if canImport(AppKit)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        #else
        return nil
        #endif
    }
}
