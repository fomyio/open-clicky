import Foundation
import AVFoundation
import ApplicationServices
import CoreGraphics
import Security

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

        /// Whether this process can raise the system's own prompt for it.
        ///
        /// False for Automation deliberately: the only way to raise that consent
        /// dialog is to *send* an Apple event, which means running a script the user
        /// did not ask for. The panel sends them to the pane instead.
        public var isRequestable: Bool {
            switch self {
            case .accessibility, .screenRecording, .microphone: return true
            case .automation, .configFile: return false
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
    /// Whether the code signature carries a team identifier. `nil` when the signature
    /// could not be read at all, which is its own answer and not a `false`.
    public let hasStableIdentity: Bool?

    public init(isBundled: Bool, bundleID: String?, hasStableIdentity: Bool?) {
        self.isBundled = isBundled
        self.bundleID = bundleID
        self.hasStableIdentity = hasStableIdentity
    }

    public static func current(bundle: Bundle = .main) -> HostIdentity {
        let identifier = bundle.bundleIdentifier
        // A SwiftPM executable still has a `Bundle.main`; what it does not have is a
        // bundle identifier, which is the thing TCC records a grant against.
        return HostIdentity(
            isBundled: identifier != nil && bundle.bundleURL.pathExtension == "app",
            bundleID: identifier,
            hasStableIdentity: Self.teamIdentifier() != nil
        )
    }

    /// Why grants may not be surviving, or nil when nothing is wrong with the host.
    public var advice: String? {
        if !isBundled {
            return """
                Running as a loose binary rather than an app bundle. macOS records \
                grants against a bundle, so this process is re-prompted on every \
                rebuild. Build OpenClicky.app with ./Scripts/bundle.sh, or — for the \
                CLI — grant Terminal/iTerm, which is the process the system actually \
                sees.
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
    public static func current(config: ConfigFile = ConfigFile()) -> PermissionAudit {
        PermissionAudit(
            grants: [
                Grant(kind: .accessibility, state: AXIsProcessTrusted() ? .granted : .denied),
                // `CGPreflightScreenCaptureAccess` cannot tell a refusal from a
                // never-asked, so this one is honestly coarse: `.denied` is the
                // conservative reading, and the request button works in both cases.
                Grant(kind: .screenRecording,
                      state: CGPreflightScreenCaptureAccess() ? .granted : .denied),
                Grant(kind: .automation, state: automationState()),
                Grant(kind: .microphone, state: microphoneState()),
                configFileGrant(config: config),
            ],
            host: .current()
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
        // procNotFound: System Events is not running, so TCC was never consulted. Not
        // a denial, and not a grant — the honest answer is that nobody asked yet.
        case -600: return .notDetermined
        default: return .unknown
        }
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

    /// The grants that are missing and requestable from inside the app, so a single
    /// button can ask for exactly those and nothing else.
    public var requestable: [Grant.Kind] {
        grants.filter { !$0.isSatisfied && $0.kind.isRequestable }.map(\.kind)
    }

    /// The whole audit as plain text, for `doctor` and for a bug report.
    public func report(mark: (Bool) -> String = { $0 ? "✓" : "✗" }) -> String {
        var lines: [String] = []
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
