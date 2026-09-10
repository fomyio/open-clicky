import Foundation
import AppKit
import ApplicationServices

/// The app the user was working in at the moment they summoned the agent.
///
/// Captured once, when the hotkey fires and *before* the overlay is on screen, and
/// then held for the conversation. It exists because the live answer to "what is the
/// user looking at" stops being the user's answer the instant this app puts a window
/// up. A recorded session in which the user asked for the VS Code command palette
/// opened with
///
///     frontmost app: OpenClicky (com.openclicky.app)
///
/// which is never true of what the user is doing and never useful to the model — the
/// same mistake as an action verifying itself against our own terminal (1a79362), or a
/// UI change we caused counting as one we observed (396839e): the agent reading its own
/// surface as the user's.
///
/// **This is narrative, and never safety.** It is stale by construction — the value is
/// minutes old by the time a long task reaches its tenth tool call — and a stale answer
/// is exactly what `Policy.escalate` must never be given: classifying a press on a
/// consent dialog from a snapshot taken before that dialog existed is how an agent ends
/// up answering its own permission prompt. Everything the gate sees is read live, at the
/// moment the risk is classified; see `AgentLoop.frontmostBundleIdentifier`, which is
/// deliberately a separate property with a name that cannot be mistaken for this one.
public struct SummonedApp: Sendable, Equatable {

    /// What to call it in the environment block — `localizedName`, the name the user
    /// would use for it.
    public let name: String

    /// Its bundle identifier, when it has one. Included because it is what the model
    /// passes to `ax_capture` and to `app_script`; the display name alone leaves it
    /// guessing at the identifier, and a guess is a tool error.
    public let bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    /// The app worth telling the model about, or nil when there is nothing true to say.
    ///
    /// Nil for OpenClicky itself, which is not a hypothetical: the hotkey is pressed
    /// while the overlay is already up, or while the Settings window has focus, or
    /// straight after a finished task left the panel on screen — and in every one of
    /// those the frontmost application really is us. Remembering that would reinstate
    /// the exact line this type exists to remove, one layer further in and harder to
    /// see. Nil, rather than a placeholder or the previous value: a probe that says
    /// nothing leaves the model to find the app the ordinary way, with `ax_capture` and
    /// a screenshot, which is what it did before any of this existed. A probe that names
    /// OpenClicky sends it somewhere it must not go.
    ///
    /// Nil also when there is no name to print. An entry with a bundle identifier and no
    /// `localizedName` is a background process, not something the user was working in.
    ///
    /// - Parameters:
    ///   - name: `NSRunningApplication.localizedName` of the app that was frontmost.
    ///   - bundleIdentifier: its bundle identifier, if it has one.
    ///   - ownBundleIdentifiers: this process's own identifiers. Passed in rather than
    ///     read from `Bundle.main` so the rule is decidable, and therefore testable,
    ///     without a bundle around it — the same reason `Conversation` and
    ///     `ProviderSelection` live in the library and not in the app target.
    public static func remembered(
        name: String?,
        bundleIdentifier: String?,
        ownBundleIdentifiers: [String]
    ) -> SummonedApp? {
        // Compared case-insensitively for the reason every other identifier comparison
        // in this project is: the volume is case-insensitive, the plist is written by
        // hand, and a single capital is all it takes for a check to stop matching.
        if let bundleIdentifier, ownBundleIdentifiers.contains(where: {
            $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) {
            return nil
        }
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return SummonedApp(name: name, bundleIdentifier: bundleIdentifier)
    }

    /// Where the last summon came from, readable from any isolation.
    ///
    /// The overlay's loop outlives any one instruction, so it cannot be handed a value
    /// at construction: the user summons from Chrome, asks for something, then summons
    /// again from VS Code and asks for something else, and both go to the same loop.
    /// The loop therefore reads this on every task, which is a read from an actor into
    /// a `@Sendable` closure — the same shape, and the same solution, as
    /// `AXCapture.labels`.
    public final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var app: SummonedApp?

        public init() {}

        /// The app the last summon came from, or nil if nothing has been remembered or
        /// the last summon came from OpenClicky itself.
        public var current: SummonedApp? {
            lock.lock(); defer { lock.unlock() }
            return app
        }

        /// Replaces what is remembered, nil included — for a caller that knows the
        /// answer has expired, such as the remembered app having quit.
        ///
        /// A summon does not go through here. See `rememberSummon`, which is the one
        /// that knows what to do about a summon from OpenClicky itself.
        public func remember(_ app: SummonedApp?) {
            lock.lock(); self.app = app; lock.unlock()
        }

        /// Records where a summon came from, and keeps what it already holds when the
        /// summon came from OpenClicky itself.
        ///
        /// Keeping, not clearing, and the distinction is the whole reason this is a
        /// method rather than a `remember(SummonedApp.remembered(…))` at the call site.
        /// The hotkey is pressed while the overlay is already up — a second instruction
        /// in the same conversation, "New conversation" from the overlay's own button,
        /// the panel left on screen by a finished task — and in every one of those the
        /// frontmost application really is us. The app the user is working in has not
        /// changed; only our window is in front of it. Clearing on that reading would
        /// throw away the correct answer and leave the probe to fall back to the live
        /// one, which is the line this whole type exists to remove:
        /// `frontmost app: OpenClicky (com.openclicky.app)`.
        ///
        /// - Returns: whether this summon supplied a new app. False means the value was
        ///   left as it was, which the caller needs to know because it also holds a
        ///   handle to that app and must not repoint it at ourselves.
        @discardableResult
        public func rememberSummon(
            from name: String?,
            bundleIdentifier: String?,
            ownBundleIdentifiers: [String]
        ) -> Bool {
            guard let arrived = SummonedApp.remembered(
                name: name,
                bundleIdentifier: bundleIdentifier,
                ownBundleIdentifiers: ownBundleIdentifiers
            ) else { return false }
            remember(arrived)
            return true
        }
    }
}

/// A cheap snapshot of what the user is looking at.
///
/// Prepended to the opening user message, once, so the model starts oriented — which
/// app is front, what the window is, what displays exist — for about fifty tokens
/// instead of the ~1,500 a screenshot costs.
///
/// Deliberately not refreshed each turn, though it goes stale the moment anything
/// activates a different app. Every `ax_capture` names the app it read on its first
/// line, and `UIFingerprint` reports a change of frontmost app after any action, so
/// the model learns the current app at the point it matters. Repeating this every
/// turn would restate what those already say, and a line that is usually redundant is
/// a line that stops being read.
public struct ContextProbe: Sendable {
    public let frontmostApp: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let displays: [String]
    public let timestamp: Date

    /// The app the user was working in when they summoned the agent, if anything
    /// remembered it. Nil for every run that has no overlay in front of it — the CLI,
    /// and the app before this value was threaded through — and nil when the only
    /// honest answer would be OpenClicky itself. See `SummonedApp`.
    public let summonedFrom: SummonedApp?

    /// - Parameter summonedFrom: the app to describe *instead of* whatever is frontmost
    ///   now. Passed in rather than read here because only the caller was present at
    ///   the moment that mattered: by the time a task runs, the live answer is this
    ///   app's own overlay.
    public static func capture(summonedFrom: SummonedApp? = nil) -> ContextProbe {
        let workspace = NSWorkspace.shared
        let front = workspace.frontmostApplication

        // Whose focused window the block describes. It has to follow the app the block
        // *names*, or the environment would say "the user was working in Code" and then
        // report the title of our own overlay under it — half a truth being the worst
        // of the three options here.
        //
        // Falls back to the live frontmost app when the remembered one is no longer
        // running, which is a real case: the user can quit it between summoning the
        // agent and pressing Return.
        let subject: NSRunningApplication? = summonedFrom
            .flatMap(\.bundleIdentifier)
            .flatMap { identifier in
                workspace.runningApplications.first { $0.bundleIdentifier == identifier }
            } ?? front

        var windowTitle: String?
        if AXIsProcessTrusted(), let pid = subject?.processIdentifier {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 1.0)
            // Type-checked before bridging: the frontmost app is whatever the user
            // happened to be looking at, and one returning a non-element here would
            // crash the probe before the run even starts.
            if let window = AXCapture.element(axApp, kAXFocusedWindowAttribute) {
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(
                    window, kAXTitleAttribute as CFString, &title
                ) == .success {
                    windowTitle = title as? String
                }
            }
        }

        // `ScreenLayout` rather than `NSScreen.screens.enumerated()`, whose order
        // AppKit does not promise and which is not the order the monitors are actually
        // arranged in. The number the model reads here is the number `screenshot` and
        // `click` route by, so the two orderings have to be one ordering.
        let displays = ScreenLayout.current().summaries

        return ContextProbe(
            frontmostApp: front?.localizedName ?? "unknown",
            bundleIdentifier: front?.bundleIdentifier,
            windowTitle: windowTitle,
            displays: displays,
            timestamp: Date(),
            summonedFrom: summonedFrom
        )
    }

    /// The half of the environment that does not change while a session runs: what
    /// screens exist, and how they are numbered.
    ///
    /// Split out of `rendered` so it can sit in the cached system prefix instead of
    /// being retyped into the opening user message of every task. It is the larger
    /// half on a multi-monitor machine and the *only* half that is worth caching —
    /// the time, the app and the window title are different on every task by
    /// definition, and a block carrying them could never be read from cache however
    /// it was ordered.
    ///
    /// A static function as well as an instance property because the loop needs this
    /// at construction, before any task and therefore before any probe: the display
    /// layout is a fact about the machine, not about the instruction being run.
    ///
    /// Empty when there are no screens, and the caller must then omit the block
    /// rather than send an empty one. A cache breakpoint on empty text is a
    /// breakpoint on nothing, which the API is entitled to reject and which would in
    /// any case spend one of the four this request gets.
    public static func staticEnvironment(displays: [String]) -> String {
        guard !displays.isEmpty else { return "" }
        return (["<screens>"] + displays + ["</screens>"]).joined(separator: "\n")
    }

    /// This machine's screens, for the cached prefix.
    public static func staticEnvironment() -> String {
        staticEnvironment(displays: ScreenLayout.current().summaries)
    }

    /// The same block, for a probe that already captured the layout.
    public var staticEnvironment: String { Self.staticEnvironment(displays: displays) }

    /// Rendered for the model. Kept terse: it is the first thing in the first turn.
    ///
    /// The screens are deliberately *not* here any more — they go in the cached system
    /// prefix via `staticEnvironment`. What is left is exactly the part that is new
    /// each task, which is what the last, uncached position in a request is for.
    public var rendered: String {
        var lines = ["<environment>"]
        lines.append("time: \(ISO8601DateFormatter().string(from: timestamp))")
        // One app line, and it names the app the user meant.
        //
        // When something remembered where the summon came from, that answer supersedes
        // the live one entirely rather than sitting beside it. A block that said both
        // would still be telling the model, on its first line, that the user is working
        // in OpenClicky — and the model has no way to know which of the two lines it is
        // supposed to act on. The live value is still captured in `frontmostApp`; it is
        // simply not what the model is oriented by.
        if let summonedFrom {
            lines.append(
                "the user was working in: \(summonedFrom.name)"
                + (summonedFrom.bundleIdentifier.map { " (\($0))" } ?? "")
            )
        } else {
            lines.append("frontmost app: \(frontmostApp)\(bundleIdentifier.map { " (\($0))" } ?? "")")
        }
        if let windowTitle { lines.append("focused window: \(windowTitle)") }
        lines.append("</environment>")
        return lines.joined(separator: "\n")
    }
}

/// Whether the TCC grants OpenClicky needs are in place.
public struct PermissionStatus: Sendable {
    public let screenRecording: Bool
    public let accessibility: Bool
    /// Whether the microphone is granted. Needed only by a voice session.
    public let microphone: Bool

    public init(screenRecording: Bool, accessibility: Bool, microphone: Bool = false) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.microphone = microphone
    }

    public static func current() -> PermissionStatus {
        PermissionStatus(
            screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted(),
            // Asked through `AudioCapture` rather than of `AVCaptureDevice` directly,
            // so the answer `doctor` prints and the answer the engine acts on come from
            // one place. Two readings of one grant is how a panel comes to say
            // "granted" beside a session that cannot hear anything.
            microphone: AudioCapture.isAuthorized
        )
    }

    /// Whether the grants an *agent run* needs are in place.
    ///
    /// The microphone is deliberately not among them, and it is the same rule
    /// `isReady(upTo:)` already applies to Screen Recording: a grant the run will never
    /// use is not a reason to call the machine unready. Every text run — which is all
    /// of them, unless a voice session is open — needs no microphone at all, and
    /// folding it in here would fail `openclicky doctor && openclicky "…"` on a machine
    /// that is entirely ready for the run it is about to do. See `voiceAdvice`.
    public var allGranted: Bool { screenRecording && accessibility }

    /// Whether `doctor` should report the machine ready, given what it found.
    ///
    /// The verdict is the exit code, so `openclicky doctor && openclicky "…"` guards a
    /// run — it used to report missing permissions and absent credentials and then
    /// exit 0, which tells a script the machine is fine. Extracted here because the
    /// version living in `main.swift` was unreachable by any test, which is how three
    /// other guards in this project came to be defended by nothing.
    ///
    /// An unreachable API is not a verdict on the key, so it is not a verdict on the
    /// machine: a laptop on a train should not be reported broken.
    ///
    /// - Parameter upTo: the highest tier this configuration can actually reach. A
    ///   grant the run will never use is not a reason to call the machine unready:
    ///   a text-only model is capped at tier 2, so demanding Screen Recording would
    ///   fail `openclicky doctor --provider ollama && openclicky "…"` on a machine
    ///   that is entirely ready for that run.
    public func isReady(
        credentials: Credentials.Verification?, upTo tier: Tier = .pixels
    ) -> Bool {
        if tier >= .pixels, !screenRecording { return false }
        if tier >= .accessibility, !accessibility { return false }
        switch credentials {
        case .working, .unreachable: return true
        // Misconfigured is a machine that is not ready: the endpoint answered, and
        // said it will not serve this request.
        case .rejected, .misconfigured, nil: return false
        }
    }

    /// What a voice session is missing, or nil when it can run.
    ///
    /// Separate from `advice(upTo:)` because it is scoped to a capability rather than
    /// to a tier, and because it is the one grant whose absence is *not* a defect in an
    /// ordinary run. Naming it a third grant matters: someone who granted Accessibility
    /// and Screen Recording during setup reasonably believes they are done, and a
    /// session that simply hears nothing gives them no way to learn otherwise.
    public var voiceAdvice: String? {
        guard !microphone else { return nil }
        return """
            Microphone access is not granted, so a voice session cannot hear anything.
              Grant it in System Settings > Privacy & Security > Microphone. This is a
              third grant, separate from Accessibility and Screen Recording.
            """
    }

    /// What is missing and how to fix it, or nil when everything is granted.
    public var advice: String? { advice(upTo: .pixels) }

    /// What is missing *that this run could have used*, and how to fix it.
    ///
    /// Scoped to the ceiling for the same reason `isReady(upTo:)` is. A run against a
    /// model that cannot be sent images has no pixel tools loaded at all, and telling
    /// its user to grant Screen Recording asks them to widen a permission the run
    /// could not have used — two lines above the run itself saying the pixel tools are
    /// absent. Advice for a capability that is not in play is noise, and noise here
    /// costs more than elsewhere: this is the text that gets read when something has
    /// already gone wrong.
    public func advice(upTo tier: Tier) -> String? {
        let wantsAccessibility = tier >= .accessibility && !accessibility
        let wantsScreenRecording = tier >= .pixels && !screenRecording
        guard wantsAccessibility || wantsScreenRecording else { return nil }

        var lines = ["Missing macOS permissions:"]
        if wantsAccessibility {
            lines.append("  • Accessibility — needed to read windows and to click/type.")
            lines.append("    System Settings ▸ Privacy & Security ▸ Accessibility")
        }
        if wantsScreenRecording {
            lines.append("  • Screen Recording — needed for screenshots.")
            lines.append("    System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording")
        }
        lines.append("")
        lines.append("Tiers 0 and 1 (shell, AppleScript) work without either.")
        return lines.joined(separator: "\n")
    }
}
