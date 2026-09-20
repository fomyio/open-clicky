import Foundation
import AVFoundation
import ApplicationServices
import CoreGraphics
import Security
import AppKit

/// One macOS privacy grant, as it stands right now.
///
/// Tri-state rather than a `Bool`, because "not granted" is two situations with two
/// different fixes and only one of them can be repaired from inside the app. A grant
/// that has never been asked for is one prompt away; a grant the user denied can only
/// be changed in System Settings, and an app that keeps calling the request API for it
/// is an app whose button does nothing. `PermissionStatus` answers the boolean question
/// this one refines, and the two agree by construction: `isSatisfied` is the only state
/// that counts as granted.
///
/// A state that cannot be confirmed is `.unknown`, and `.unknown` is not satisfied.
/// That is the same rule `AudioCapture.hasEchoCancellation` follows and for the same
/// reason: guessing the optimistic way produces a panel that says the machine is ready
/// beside a run that cannot move.
public enum GrantState: String, Sendable, Equatable, CaseIterable {
    /// The user has granted it.
    case granted
    /// The user has refused it, or the system forbids it. Only System Settings fixes this.
    case denied
    /// Never asked. One prompt away.
    case notDetermined
    /// The system would not say. Treated as missing — see the note above.
    case unknown

    public var isSatisfied: Bool { self == .granted }

    /// What the settings window and `doctor` call it.
    public var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not requested yet"
        case .unknown: return "could not be determined"
        }
    }
}

/// A permission OpenClicky needs, and whether this process holds it.
public struct Grant: Sendable, Equatable, Identifiable {

    /// Every permission that decides whether some part of this app works.
    ///
    /// Five, not the two `doctor` used to print. The three that were missing are each
    /// a documented way for the agent to fail silently:
    ///
    /// - **Automation** is a *different TCC principal* from Accessibility — see
    ///   `ScriptTools.automationDenials`. Tier 1 is the differentiator of this whole
    ///   project and it is gated by a permission nothing in the app ever reported on.
    /// - **Microphone** is the third grant, and a session without it simply hears
    ///   nothing; someone who granted the other two reasonably believes they are done.
    /// - **Config file protection** is not a TCC grant, but it is a permission, it is
    ///   checked on every credential read, and while it is wrong the agent silently
    ///   refuses to honour a stored Auto mode. Leaving it off a permissions panel
    ///   would put the one repairable-by-the-user failure somewhere else.
    public enum Kind: String, Sendable, CaseIterable, Identifiable {
        case accessibility
        case screenRecording
        case automation
        case microphone
        case configFile

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            case .automation: return "Automation (Apple Events)"
            case .microphone: return "Microphone"
            case .configFile: return "Config file protection"
            }
        }

        /// What stops working without it, in the user's terms rather than the API's.
        public var purpose: String {
            switch self {
            case .accessibility:
                return "Read windows and menus, and click and type on your behalf."
            case .screenRecording:
                return "Take the screenshots the agent looks at."
            case .automation:
                return "Drive scriptable apps with AppleScript — the fastest, most reliable route."
            case .microphone:
                return "Hear you during a voice session, and let you interrupt mid-sentence."
            case .configFile:
                return "Keep API keys and the approval setting readable only by you."
            }
        }

        /// What the probe for this grant actually established, where that is narrower than
    /// the row's title suggests.
    ///
    /// Automation is the only one that needs it, and it needs it badly. macOS records an
    /// Automation grant *per target app*, so the pane under OpenClicky lists System
    /// Events and nothing else until a task drives some other app — which reads as the
    /// grant being incomplete. It is not: System Events is the target every UI-scripting
    /// snippet goes through, and the rest are asked for on first use, one dialog per app.
    /// A row that said a bare "granted" would be claiming something it never checked.
    public var scope: String? {
        switch self {
        case .automation:
            return """
                Checked against System Events, which every UI-scripting snippet goes \
                through. macOS grants Automation per target app, so other apps appear \
                in this pane — and ask once — as tasks reach them.
                """
        case .accessibility, .screenRecording, .microphone, .configFile:
            return nil
        }
    }

    /// The tiers that stop working without it.
        ///
        /// Empty for the two that are not on the ladder at all: the microphone gates a
        /// voice session and the config file gates every run equally, and folding
        /// either into a tier would make the ladder describe something it does not.
        public var tiers: [Tier] {
            switch self {
            case .accessibility: return [.accessibility, .pixels]
            case .screenRecording: return [.pixels]
            case .automation: return [.script]
            case .microphone, .configFile: return []
            }
        }

        /// The System Settings pane that grants it, or nil where there is none.
        ///
        /// The anchors are the ones macOS has used since Ventura. A URL that stops
        /// resolving opens Privacy & Security at the top, which is wrong but harmless;
        /// the row says which pane to look for either way, so the text is never the
        /// only thing pointing the user at the right place.
        public var settingsURL: URL? {
            let root = "x-apple.systempreferences:com.apple.preference.security"
            switch self {
            case .accessibility: return URL(string: "\(root)?Privacy_Accessibility")
            case .screenRecording: return URL(string: "\(root)?Privacy_ScreenCapture")
            case .automation: return URL(string: "\(root)?Privacy_Automation")
            case .microphone: return URL(string: "\(root)?Privacy_Microphone")
            case .configFile: return nil
            }
        }

        /// Where the user has to go, named in words for the cases the URL cannot open.
        public var settingsPath: String? {
            switch self {
            case .accessibility:
                return "System Settings ▸ Privacy & Security ▸ Accessibility"
            case .screenRecording:
                return "System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording"
            case .automation:
                return "System Settings ▸ Privacy & Security ▸ Automation"
            case .microphone:
                return "System Settings ▸ Privacy & Security ▸ Microphone"
            case .configFile:
                return nil
            }
        }

        /// Whether raising this grant's prompt is itself an action on another app.
        ///
        /// True only for Automation, and that is why it is a property rather than a
        /// detail of one call site: its consent dialog cannot be raised by asking macOS
        /// about this process — the only way is to *send* an Apple event, which means
        /// launching a target application and driving it. Every other grant here is a
        /// question about ourselves.
        ///
        /// So the rule it carries is not "may this be asked for" but "may it happen
        /// without someone asking for it". No surface may raise this on a timer, on
        /// appearing, or as a side effect of reading a row — and the control that does
        /// raise it has to say what pressing it will do, which is `requestLabel` and
        /// `requestSummary`. A click on a button that says so is the same consent
        /// `openclicky grant` gets from being typed; withholding the button instead left
        /// the row that gates the whole of tier 1 with no way forward but to trip the
        /// prompt by accident during a task.
        public var requestDrivesAnotherApp: Bool {
            switch self {
            case .automation: return true
            case .accessibility, .screenRecording, .microphone, .configFile: return false
            }
        }

        /// What the button that raises this prompt says.
        ///
        /// The ellipsis is the platform's own promise that something further follows it,
        /// and here it also separates a button that asks macOS a question from one that
        /// starts an application to ask it.
        public var requestLabel: String {
            requestDrivesAnotherApp ? "Request…" : "Request"
        }

        /// The sentence shown with that button, or nil where the label is the whole story.
        ///
        /// Lives here rather than in the view because it is a claim about what pressing
        /// the button does, and a claim that drifts from the code it describes is worse
        /// than no claim at all — this way one test reads both.
        public var requestSummary: String? {
            guard requestDrivesAnotherApp else { return nil }
            return """
                Starts System Events and asks it for permission, which is what raises \
                macOS's consent dialog. Nothing is scripted: the question is the whole \
                action.
                """
        }

        /// Whether macOS can be asked for it at all.
        ///
        /// The only axis that decides *whether* a prompt may be offered. Every caller
        /// that asks is one the user set in motion — by typing `openclicky grant`, or by
        /// pressing Request — so the question "who asked" is answered at the control,
        /// not by a table. What still differs per grant is *how* the asking happens, and
        /// that is `requestDrivesAnotherApp`.
        ///
        /// The config file is the one exception: its mode is this tool's to fix, not the
        /// system's to be asked about.
        public var isGrantable: Bool {
            switch self {
            case .accessibility, .screenRecording, .microphone, .automation: return true
            case .configFile: return false
            }
        }

        /// Whether a grant given now takes effect only after the process restarts.
        ///
        /// True for the two the kernel caches per-process. A CLI that requested Screen
        /// Recording, was granted it, and then reported itself still unready looks like
        /// the grant failed — so the command that asks has to say which answers will not
        /// change until the terminal is relaunched, rather than leaving the user to
        /// re-run `doctor` and conclude nothing happened.
        public var requiresRelaunch: Bool {
            switch self {
            case .accessibility, .screenRecording: return true
            case .microphone, .automation, .configFile: return false
            }
        }

        /// Whether a `.denied` on this row is a refusal the probe actually established.
        ///
        /// False for the two whose preflight is a bare `Bool`. `AXIsProcessTrusted()` and
        /// `CGPreflightScreenCaptureAccess()` answer "not granted" identically for a grant
        /// the user refused and one nobody has ever asked for, and `current()` records the
        /// conservative `.denied` for both — as the screen-recording probe's own comment
        /// says, the request API works in either case. A surface that read that `.denied`
        /// as a refusal withheld the Request button from exactly the two rows the request
        /// API exists for, so the panel offered it on one row of five.
        ///
        /// True for the microphone, whose `authorizationStatus` distinguishes the two: a
        /// second request there raises no dialog at all, and a button that does nothing is
        /// worse than no button.
        public var deniedIsARefusal: Bool {
            switch self {
            case .accessibility, .screenRecording: return false
            case .microphone, .automation, .configFile: return true
            }
        }
    }

    public let kind: Kind
    public let state: GrantState
    /// Anything the probe learned beyond the state — the config file's own complaint,
    /// for one. Never a restatement of `state`.
    public let detail: String?

    public var id: String { kind.rawValue }

    public init(kind: Kind, state: GrantState, detail: String? = nil) {
        self.kind = kind
        self.state = state
        self.detail = detail
    }

    public var isSatisfied: Bool { state.isSatisfied }
}

/// Whether one rung of the capability ladder can actually be used on this machine.
public struct TierReadiness: Sendable, Equatable, Identifiable {
    public let tier: Tier
    /// The grants this tier needs and does not have, in ladder order.
    public let missing: [Grant.Kind]

    public var id: Int { tier.rawValue }
    public var isReady: Bool { missing.isEmpty }

    public init(tier: Tier, missing: [Grant.Kind]) {
        self.tier = tier
        self.missing = missing
    }

    /// One line, for a row that has to say what is wrong without being read twice.
    public var summary: String {
        guard !isReady else { return "ready" }
        return "needs " + missing.map(\.title).joined(separator: " and ")
    }
}

/// What this process is, as far as TCC is concerned.
///
/// The question behind "my permissions keep disappearing". macOS keys an ad-hoc app's
/// grants to its cdhash, which changes on every rebuild, so an unsigned or ad-hoc
/// `OpenClicky.app` silently drops Accessibility and Screen Recording each time
/// `bundle.sh` runs — three separate attempts to verify a fix died on exactly that, each
/// looking like the fix had failed. A permissions panel that shows only the grants would
/// show them flipping to "not granted" with no account of why.
public struct HostIdentity: Sendable, Equatable {
    /// Whether this is running from a real `.app`, rather than as a loose binary.
    public let isBundled: Bool
    public let bundleID: String?
    /// What macOS actually answers for when asked about these grants.
    ///
    /// The subject the rows were always missing. TCC answers for a *process*, and for a
    /// CLI that process is the terminal it was typed into — so `doctor` and the app's
    /// panel routinely disagree about Screen Recording while both are telling the truth
    /// about different principals. Read side by side that looks like one of them is
    /// broken, and the reader has no way to tell which.
    ///
    /// It was found the way these things are: a screenshot from a shell failed with
    /// "could not create image from display" at the same moment the app's own panel
    /// said Screen Recording was granted. The process tree explained it — the shell's
    /// TCC-responsible ancestor was Terminal, not OpenClicky — but nothing in either
    /// report said whose answer it was giving.
    public let principal: String
    /// Whether the code signature carries a team identifier. `nil` when the signature
    /// could not be read at all, which is its own answer and not a `false`.
    public let hasStableIdentity: Bool?

    public init(
        isBundled: Bool, bundleID: String?, hasStableIdentity: Bool?,
        principal: String = "this process"
    ) {
        self.isBundled = isBundled
        self.bundleID = bundleID
        self.hasStableIdentity = hasStableIdentity
        self.principal = principal
    }

    public static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HostIdentity {
        let identifier = bundle.bundleIdentifier
        // A SwiftPM executable still has a `Bundle.main`; what it does not have is a
        // bundle identifier, which is the thing TCC records a grant against.
        let isBundled = identifier != nil && bundle.bundleURL.pathExtension == "app"
        return HostIdentity(
            isBundled: isBundled,
            bundleID: identifier,
            hasStableIdentity: Self.teamIdentifier() != nil,
            principal: principal(isBundled: isBundled, bundle: bundle, environment: environment)
        )
    }

    /// Who these grants belong to, in the words a person would use.
    ///
    /// A bundled app answers for itself. Everything else is a CLI, and a CLI's grants
    /// are its terminal's — named where `TERM_PROGRAM` identifies one, and left as
    /// "the terminal you ran this from" where it does not, because naming the wrong
    /// application sends someone to change a setting on an app that is not involved.
    static func principal(
        isBundled: Bool, bundle: Bundle, environment: [String: String]
    ) -> String {
        if isBundled {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            return name ?? bundle.bundleIdentifier ?? "this app"
        }
        return HostTerminal.name(environment: environment) ?? "the terminal you ran this from"
    }

    /// Why grants may not be surviving, or nil when nothing is wrong with the host.
    public var advice: String? {
        if !isBundled {
            return """
                These are \(principal)'s grants, not OpenClicky's. A CLI inherits the \
                TCC grants of the process it was launched from, so this list can differ \
                from what OpenClicky.app's own Settings window shows — and both are \
                right about different processes. Grant \(principal) what this run needs, \
                or use OpenClicky.app, which macOS records grants against by bundle.
                """
        }
        switch hasStableIdentity {
        case false:
            return """
                This build is ad-hoc signed, so macOS keys its grants to the binary's \
                contents and drops every one of them on the next rebuild. Set \
                OPENCLICKY_SIGN_IDENTITY, or install a Developer ID certificate, then \
                re-grant once.
                """
        case nil:
            return "The code signature could not be read, so whether grants will survive a rebuild is unknown."
        case true?:
            return nil
        }
    }

    /// The team identifier of the running code, or nil when there is none — which is
    /// what ad-hoc signing looks like from the inside.
    private static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Every permission this app needs, probed at once, with the ladder read off them.
///
/// The value type is the point. `current()` is the only part that touches the system,
/// and everything a surface asks — which tiers work, what is missing, what to say about
/// it — is derived from the array, so all of it is reachable by a test. The version of
/// this that lived in `doctor` answered two of the five questions and could only be
/// checked by running it on a Mac and reading the output.
public struct PermissionAudit: Sendable, Equatable {

    public let grants: [Grant]
    public let host: HostIdentity

    public init(grants: [Grant], host: HostIdentity = HostIdentity(
        isBundled: true, bundleID: nil, hasStableIdentity: true
    )) {
        // Stored in `Kind.allCases` order rather than as handed in, so two audits with
        // the same contents are equal and a surface cannot reorder its own rows by
        // probing in a different sequence.
        self.grants = Kind.allCases.compactMap { kind in
            grants.first { $0.kind == kind }
        }
        self.host = host
    }

    private typealias Kind = Grant.Kind

    /// Asks the system about all five. Never prompts: every probe here is a preflight.
    ///
    /// A panel that raised a consent dialog merely by being opened would train its user
    /// to dismiss the prompts that matter, and `doctor` is run from scripts.
    /// - Parameter resolvingAutomation: whether to start System Events before asking
    ///   about it.
    ///
    ///   Default false, and that default is the consent rule this type keeps: a *reader*
    ///   of a permission must not launch an application as a side effect of being read,
    ///   any more than a settings window may raise a consent dialog because it opened.
    ///   The two-second poll behind the panel gets `false`.
    ///
    ///   `doctor` and `grant` pass `true`, because they are commands somebody typed —
    ///   and because without it they answer wrongly. System Events is launched on demand
    ///   and idle most of the time, so the passive probe reports "could not be
    ///   determined" on a machine that holds the grant, and `doctor`'s job is to be
    ///   right about that rather than fast.
    public static func current(
        config: ConfigFile = ConfigFile(), resolvingAutomation: Bool = false
    ) -> PermissionAudit {
        PermissionAudit(
            grants: [
                Grant(kind: .accessibility, state: AXIsProcessTrusted() ? .granted : .denied),
                // `CGPreflightScreenCaptureAccess` cannot tell a refusal from a
                // never-asked, so this one is honestly coarse: `.denied` is the
                // conservative reading, and the request button works in both cases.
                Grant(kind: .screenRecording,
                      state: CGPreflightScreenCaptureAccess() ? .granted : .denied),
                automationGrant(resolving: resolvingAutomation),
                Grant(kind: .microphone, state: microphoneState()),
                configFileGrant(config: config),
            ],
            host: .current()
        )
    }

    /// The Automation row, with the reason attached when the answer could not be had.
    ///
    /// Deliberately does not launch System Events to get a better answer. `current()` is
    /// called on a two-second timer by the settings window, and a *reader* of a
    /// permission that starts an application as a side effect of being read is the same
    /// mistake as a panel that raises a consent dialog because it opened. `grant`, and
    /// the panel's explicit Check, are where that is allowed — see `requestAutomation`.
    static func automationGrant(resolving: Bool = false) -> Grant {
        automationGrant(state: resolving ? resolveAutomation() : automationState())
    }

    /// The row a probed Automation state produces — every branch, no TCC.
    ///
    /// Split from the probe above because the whole decision is here: which states get a
    /// `detail`, and what each one says. Left inline, the two sentences below were
    /// reachable only by a test that could put the real System Events into a chosen
    /// state, which is to say by no test at all.
    static func automationGrant(state: GrantState) -> Grant {
        // The question the pane cannot answer for itself. macOS lists an app under
        // Privacy & Security ▸ Automation only once it has *asked*, and there is no way
        // to add one — so someone sent there by a row reading "not requested yet" finds
        // an empty pane, no switch to turn on, and no way to tell a missing grant from a
        // broken build. Naming that on the row is what makes the Request button legible.
        if state == .notDetermined {
            return Grant(
                kind: .automation,
                state: state,
                detail: """
                    Nothing to switch on in System Settings yet: macOS lists an app under \
                    Automation only after it has asked once, and the pane stays empty \
                    until then. Request is what asks.
                    """
            )
        }
        guard state == .unknown else { return Grant(kind: .automation, state: state) }
        return Grant(
            kind: .automation,
            state: state,
            detail: """
                System Events is not running, so macOS could not be asked. This is not a \
                refusal — run `openclicky grant`, or use Check, to start it and find out.
                """
        )
    }

    /// Whether the AppleScript/System Events route is permitted.
    ///
    /// This is the permission `AXIsProcessTrusted()` does *not* answer for, and the gap
    /// between the two is a documented dead end in this project: a run with Accessibility
    /// granted gave up on "open the command palette" because `osascript` came back "not
    /// allowed to send keystrokes (1002)", which reads as a broken machine rather than as
    /// one missing grant. `AEDeterminePermissionToAutomateTarget` answers it without
    /// sending an event the user did not ask for — `askUserIfNeeded: false` is what keeps
    /// this a probe rather than a prompt.
    ///
    /// System Events is the target because it is the one every UI-scripting snippet goes
    /// through; per-app Automation grants are separate and cannot be enumerated ahead of
    /// knowing which app a task will touch.
    static func automationState(targetBundleID: String = "com.apple.systemevents") -> GrantState {
        var target = AEDesc()
        let bytes = Array(targetBundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target)
        }
        guard created == 0 else { return .unknown }
        defer { AEDisposeDesc(&target) }
        return interpretAutomation(
            AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        )
    }

    /// The OSStatus values `AEDeterminePermissionToAutomateTarget` answers with.
    ///
    /// Written as literals with their names in the comments rather than taken from the
    /// Carbon symbols: `errAEEventWouldRequireUserConsent` is the one that separates
    /// "never asked" from "refused", it has been unavailable to Swift on and off, and a
    /// build that falls back to lumping the two together produces a panel offering a
    /// prompt the system will never show. Split out so the mapping is testable without
    /// an Apple event.
    static func interpretAutomation(_ status: OSStatus) -> GrantState {
        switch status {
        case 0: return .granted                       // noErr
        case -1743: return .denied                    // errAEEventNotPermitted
        case -1744: return .notDetermined             // errAEEventWouldRequireUserConsent
        // procNotFound. **Not** "never asked", which is what this returned and what made
        // the row lie: System Events is launched on demand and is idle most of the time,
        // so a machine that *holds* the grant reports it missing whenever nothing has
        // driven a script recently. Measured on a machine where Terminal had the grant:
        // the probe said `-600` cold, and `noErr` a second after System Events started.
        //
        // That produced two surfaces disagreeing for a third time — `doctor` from a
        // terminal said "not requested yet" while the app's panel said "granted", purely
        // because the agent had been scripting and the shell had not. Unknown is the
        // honest answer, it is not satisfied, and `Grant.detail` says why so the row
        // explains itself instead of claiming a refusal nobody made.
        case -600: return .unknown
        default: return .unknown
        }
    }

    /// Starts an application without bringing it forward, and waits briefly for it.
    ///
    /// Synchronous because both callers are explicit, user-initiated actions that have
    /// nothing else to do until this answers. `activates: false` so a permissions check
    /// does not steal the user's focus — System Events has no window to show anyway, and
    /// a helper stealing the foreground is its own small breach of *our own surface is
    /// not the user's*.
    static func launch(_ bundleIdentifier: String) {
        guard !NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let started = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            started.signal()
        }
        _ = started.wait(timeout: .now() + 5)
        // The process exists before it is ready to answer Apple events. Measured: the
        // probe returns the real answer about a second after launch, and `procNotFound`
        // immediately after it.
        Thread.sleep(forTimeInterval: 1)
    }

    /// Probes Automation after making sure the target is running.
    ///
    /// The explicit counterpart of `automationGrant()`, for a surface the user just
    /// clicked. Does not prompt — it only removes the reason the answer was unavailable.
    public static func resolveAutomation(
        targetBundleID: String = "com.apple.systemevents"
    ) -> GrantState {
        launch(targetBundleID)
        return automationState(targetBundleID: targetBundleID)
    }

    static func microphoneState() -> GrantState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func configFileGrant(config: ConfigFile) -> Grant {
        guard let problem = config.permissionProblem() else {
            return Grant(kind: .configFile, state: .granted)
        }
        // `.denied` rather than `.unknown`: the file exists, the mode was read, and the
        // answer is no. The detail carries the mode and the chmod that fixes it.
        return Grant(kind: .configFile, state: .denied, detail: "\(problem)")
    }

    // MARK: - Reading it

    public func grant(_ kind: Grant.Kind) -> Grant {
        grants.first { $0.kind == kind } ?? Grant(kind: kind, state: .unknown)
    }

    /// What a row says in place of its probed state, once this process has asked for a
    /// grant whose answer it will not see change.
    ///
    /// Two strings rather than one, because the row has two places to put them and a
    /// surface that had to split a sentence itself would split it differently from the
    /// next one.
    public struct RelaunchNotice: Sendable, Equatable {
        /// Replaces `GrantState.label` beside the title — where "denied" would otherwise
        /// sit, in the same register and about the same length.
        public let label: String
        /// The sentence under it, which is the part that tells the user what to do.
        public let detail: String

        public init(label: String, detail: String) {
            self.label = label
            self.detail = detail
        }
    }

    /// The notice for a grant this process asked for and cannot see, or nil where the
    /// probed state is still the honest word.
    ///
    /// The settings window's Request button looked broken and was not. Accessibility and
    /// Screen Recording are cached per process, so someone who pressed Request, granted in
    /// the system prompt, and came back watched `watchPermissions()` repaint "denied" on
    /// that row every two seconds — the one outcome indistinguishable from the grant
    /// having failed. `doctor` had said this since it was written; the panel had not.
    ///
    /// It deliberately does not say the grant was *given*. This process cannot know: the
    /// kernel's cached answer is the only one it can read, and it reads the same whether
    /// the user granted, refused, or closed the prompt. All the notice claims is that no
    /// answer will appear here until a restart.
    ///
    /// - Parameter requestedThisSession: whether this process has raised the system's
    ///   prompt for `kind`. A surface that has never asked must keep saying "denied" —
    ///   nothing about that row is stale yet.
    public func relaunchNotice(
        for kind: Grant.Kind, requestedThisSession: Bool
    ) -> RelaunchNotice? {
        guard requestedThisSession, kind.requiresRelaunch, !grant(kind).isSatisfied else {
            return nil
        }
        return RelaunchNotice(
            label: "asked — restart to see the answer",
            detail: """
                \(host.principal) asked for this, and macOS decides it once per process: \
                this row cannot change — either way — until \(host.principal) is \
                relaunched. Quit and reopen it, then look here again.
                """
        )
    }

    /// Whether a surface should offer to raise the system's prompt for `kind`.
    ///
    /// The whole rule in one place, because the panel had two thirds of it inline and got
    /// the third wrong in both directions: it hid the button behind a `.denied` that two
    /// probes cannot distinguish from a never-asked, and it kept offering it after a
    /// request whose answer this process is not allowed to see — so pressing it again
    /// raised the same prompt for a grant the user had already given.
    ///
    /// Automation is in scope here now. It is offered because pressing a button is an
    /// explicit ask and the label says what the press will do; the separate rule that it
    /// must never fire on its own is `Grant.Kind.requestDrivesAnotherApp`. A real refusal
    /// still takes the button away below — `errAEEventNotPermitted` is established, and
    /// asking again after it raises nothing.
    public func canRequest(_ kind: Grant.Kind, requestedThisSession: Bool) -> Bool {
        let grant = self.grant(kind)
        guard !grant.isSatisfied, kind.isGrantable else { return false }
        // A refusal the probe actually established. Asking again produces no dialog.
        if grant.state == .denied, kind.deniedIsARefusal { return false }
        // Asked, and the answer is cached for this process's lifetime. A second press
        // cannot move the row, so the row gets `relaunchNotice` instead of a button.
        return !(kind.requiresRelaunch && requestedThisSession)
    }

    public func state(of kind: Grant.Kind) -> GrantState { grant(kind).state }

    /// Which grants a tier needs, in ladder order.
    public static func requirements(of tier: Tier) -> [Grant.Kind] {
        Grant.Kind.allCases.filter { $0.tiers.contains(tier) }
    }

    public func readiness(of tier: Tier) -> TierReadiness {
        TierReadiness(
            tier: tier,
            missing: Self.requirements(of: tier).filter { !grant($0).isSatisfied }
        )
    }

    /// Every rung, lowest first. The shape the settings panel draws.
    public var ladder: [TierReadiness] { Tier.allCases.map(readiness(of:)) }

    /// The highest tier this machine can actually reach right now.
    ///
    /// Read *upward from tier 0 and stopped at the first gap*, which is the only
    /// reading that matches how a run behaves: the model is offered a contiguous
    /// registry capped at one tier, so Screen Recording granted while Accessibility is
    /// not does not make tier 3 usable — `click` and `type` both go through the grant
    /// that is missing.
    public var reachableTier: Tier {
        var best = Tier.shell
        for tier in Tier.allCases.sorted(by: <) {
            guard readiness(of: tier).isReady else { break }
            best = tier
        }
        return best
    }

    /// Whether every grant on the ladder is in place. Says nothing about the microphone
    /// — the same rule `PermissionStatus.allGranted` follows, for the same reason: a
    /// grant no text run will ever use is not a reason to call the machine unready.
    public var isLadderComplete: Bool { readiness(of: .pixels).isReady }

    /// Whether a voice session can hear anything.
    public var canHear: Bool { grant(.microphone).isSatisfied }

    /// The grants `openclicky grant` would ask for: missing, and askable at all.
    ///
    /// Already-granted entries are excluded rather than re-requested. Asking again for
    /// something held produces no dialog, so a command that "asked for five things" and
    /// showed two prompts reads as three failures.
    public var grantable: [Grant.Kind] {
        grants.filter { !$0.isSatisfied && $0.kind.isGrantable }.map(\.kind)
    }

    /// Raises the Automation consent dialog by asking permission to automate a target.
    ///
    /// The prompting counterpart of `automationState()`, and the same call with
    /// `askUserIfNeeded: true` — which is what makes it a request rather than a probe.
    /// Separated so the two uses cannot be confused at a call site: every passive reader
    /// in this codebase must get the probe, and only a command the user typed may get
    /// this.
    ///
    /// Blocks until the dialog is dismissed. That is correct for a CLI, which has
    /// nothing else to do, and is why no window-server caller is offered it.
    ///
    /// - Returns: the state afterwards.
    @discardableResult
    public static func requestAutomation(
        targetBundleID: String = "com.apple.systemevents"
    ) -> GrantState {
        // Started first, and this is the whole reason the request used to do nothing:
        // `AEDeterminePermissionToAutomateTarget` answers `procNotFound` for a target
        // that is not running and raises no dialog at all, whatever `askUserIfNeeded`
        // says. Asking macOS about a process that does not exist cannot prompt.
        launch(targetBundleID)
        var target = AEDesc()
        let bytes = Array(targetBundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target)
        }
        guard created == 0 else { return .unknown }
        defer { AEDisposeDesc(&target) }
        return interpretAutomation(
            AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, true)
        )
    }

    /// The whole audit as plain text, for `doctor` and for a bug report.
    public func report(mark: (Bool) -> String = { $0 ? "✓" : "✗" }) -> String {
        // Named first, because without it every row below is a claim with no subject.
        var lines = ["  Grants held by \(host.principal):", ""]
        for grant in grants {
            let title = grant.kind.title.padding(toLength: 26, withPad: " ", startingAt: 0)
            lines.append("  \(mark(grant.isSatisfied)) \(title)\(grant.state.label)")
        }
        lines.append("")
        for rung in ladder {
            lines.append("  \(mark(rung.isReady)) \(rung.tier.label) — \(rung.summary)")
        }
        lines.append("  \(mark(canHear)) Voice session — \(canHear ? "ready" : "needs Microphone")")
        return lines.joined(separator: "\n")
    }
}
