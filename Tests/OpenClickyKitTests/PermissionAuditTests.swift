import Testing
import Foundation
@testable import OpenClickyKit

/// The permissions panel's whole reason to exist is that every one of these failures is
/// silent at the point of use. So the reasoning over them — which tiers a missing grant
/// takes out, what the ladder actually reaches, whether an unconfirmable answer counts —
/// is a value computation with no TCC in it, and that is the part these hold.
///
/// `PermissionAudit.current()` is the one function here that talks to the system, and it
/// is a probe with no branches. Everything with a decision in it is below.
@Suite("Permission audit")
struct PermissionAuditTests {

    private func audit(
        accessibility: GrantState = .granted,
        screenRecording: GrantState = .granted,
        automation: GrantState = .granted,
        microphone: GrantState = .granted,
        configFile: GrantState = .granted,
        host: HostIdentity = HostIdentity(isBundled: true, bundleID: "x", hasStableIdentity: true)
    ) -> PermissionAudit {
        PermissionAudit(grants: [
            Grant(kind: .accessibility, state: accessibility),
            Grant(kind: .screenRecording, state: screenRecording),
            Grant(kind: .automation, state: automation),
            Grant(kind: .microphone, state: microphone),
            Grant(kind: .configFile, state: configFile),
        ], host: host)
    }

    // MARK: - What "granted" means

    /// The rule the whole type rests on, and the one `AudioCapture.hasEchoCancellation`
    /// already follows: a capability that cannot be confirmed is treated as absent.
    /// Guessing the optimistic way produces a panel that calls the machine ready beside
    /// a run that cannot move.
    @Test("Only an outright grant counts as one")
    func unconfirmedIsNotGranted() {
        #expect(GrantState.granted.isSatisfied)
        #expect(!GrantState.denied.isSatisfied)
        #expect(!GrantState.notDetermined.isSatisfied)
        #expect(!GrantState.unknown.isSatisfied)
    }

    /// The gap this project spent a run discovering: `AXIsProcessTrusted()` does not
    /// answer for the Apple-events principal, so tier 1 can be denied on a machine that
    /// reports Accessibility granted. The two must never be collapsed.
    @Test("Automation gates tier 1 and Accessibility does not")
    func automationIsItsOwnGrant() {
        #expect(Grant.Kind.automation.tiers == [.script])
        #expect(Grant.Kind.accessibility.tiers == [.accessibility, .pixels])
        #expect(Grant.Kind.screenRecording.tiers == [.pixels])

        let denied = audit(automation: .denied)
        #expect(!denied.readiness(of: .script).isReady)
        #expect(denied.readiness(of: .accessibility).isReady)
        #expect(denied.grant(.accessibility).isSatisfied)
    }

    /// Neither is on the ladder, and folding either in would make the ladder describe
    /// something it does not: a text run needs no microphone, and the config file gates
    /// every tier equally rather than one of them.
    @Test("The microphone and the config file belong to no tier")
    func offLadderGrants() {
        #expect(Grant.Kind.microphone.tiers.isEmpty)
        #expect(Grant.Kind.configFile.tiers.isEmpty)
        #expect(audit(microphone: .denied).isLadderComplete)
        #expect(!audit(microphone: .denied).canHear)
    }

    // MARK: - The ladder

    /// The reading that matches how a run behaves. The model is offered a *contiguous*
    /// registry capped at one tier, so Screen Recording granted while Accessibility is
    /// not does not make tier 3 usable — `click` and `type` both go through the grant
    /// that is missing, and reporting "tier 3 available" would be the panel promising
    /// something the run cannot do.
    @Test("The reachable tier stops at the first gap, not the last")
    func reachableTierIsContiguous() {
        #expect(audit().reachableTier == .pixels)
        #expect(audit(screenRecording: .denied).reachableTier == .accessibility)
        #expect(audit(accessibility: .denied).reachableTier == .script)
        #expect(audit(automation: .denied).reachableTier == .shell)
        // The case the naive reading gets wrong: everything above the gap is granted.
        #expect(audit(screenRecording: .granted, automation: .denied).reachableTier == .shell)
    }

    @Test("Tier 0 needs nothing and is always reachable")
    func shellNeedsNoGrant() {
        #expect(PermissionAudit.requirements(of: .shell).isEmpty)
        let nothing = audit(
            accessibility: .denied, screenRecording: .denied,
            automation: .denied, microphone: .denied, configFile: .denied
        )
        #expect(nothing.readiness(of: .shell).isReady)
        #expect(nothing.reachableTier == .shell)
    }

    @Test("A rung names every grant it is missing")
    func rungNamesWhatIsMissing() {
        let rung = audit(accessibility: .denied, screenRecording: .denied).readiness(of: .pixels)
        #expect(rung.missing == [.accessibility, .screenRecording])
        #expect(rung.summary.contains("Accessibility"))
        #expect(rung.summary.contains("Screen Recording"))
    }

    // MARK: - Asking for them

    /// A button that does nothing when clicked is worse than no button. Automation's
    /// consent dialog can only be raised by *sending* an Apple event — running a script
    /// nobody asked for — so it is never offered as requestable.
    @Test("Only the grants macOS will actually prompt for are offered")
    func requestableExcludesAutomation() {
        let missing = audit(
            accessibility: .notDetermined, screenRecording: .denied,
            automation: .denied, microphone: .notDetermined, configFile: .denied
        )
        #expect(missing.requestable == [.accessibility, .screenRecording, .microphone])
        #expect(!Grant.Kind.automation.isRequestable)
        #expect(!Grant.Kind.configFile.isRequestable)
    }

    /// The difference between the two is *consent*, not capability. Automation's dialog
    /// only appears if an Apple event is actually sent — a window doing that because it
    /// opened is a window driving another application unasked, while someone who typed
    /// `openclicky grant` has given exactly that permission.
    @Test("Only an explicitly-typed command may ask for Automation")
    func automationIsGrantableButNotRequestable() {
        #expect(!Grant.Kind.automation.isRequestable)
        #expect(Grant.Kind.automation.isGrantable)
        // The config file is neither: its mode is this tool's to fix, not the system's.
        #expect(!Grant.Kind.configFile.isRequestable)
        #expect(!Grant.Kind.configFile.isGrantable)
        // Everything a panel may prompt for, a command may too.
        for kind in Grant.Kind.allCases where kind.isRequestable {
            #expect(kind.isGrantable, "\(kind.rawValue) is requestable but not grantable")
        }
    }

    @Test("`grant` asks only for what is missing, and never for the config file")
    func grantableIsScopedToWhatIsMissing() {
        #expect(audit().grantable.isEmpty)
        let missing = audit(
            accessibility: .denied, screenRecording: .granted,
            automation: .notDetermined, microphone: .denied, configFile: .denied
        )
        #expect(missing.grantable == [.accessibility, .automation, .microphone])
    }

    /// The line that stops a successful grant looking like a failed one: these two are
    /// cached per process, so the command that asked keeps reporting them missing
    /// however many times it re-runs.
    @Test("The grants that need a relaunch are the ones the kernel caches")
    func relaunchIsNamedForTheRightGrants() {
        #expect(Grant.Kind.accessibility.requiresRelaunch)
        #expect(Grant.Kind.screenRecording.requiresRelaunch)
        // These answer immediately in-process, so claiming otherwise would send someone
        // to restart a terminal for no reason.
        #expect(!Grant.Kind.microphone.requiresRelaunch)
        #expect(!Grant.Kind.automation.requiresRelaunch)
    }

    @Test("Every grant that a pane can fix names one, and names it in words too")
    func everyTCCGrantHasAPane() {
        for kind in Grant.Kind.allCases where kind != .configFile {
            #expect(kind.settingsURL != nil, "\(kind.rawValue) has no pane to open")
            #expect(kind.settingsPath != nil, "\(kind.rawValue) has no pane to name")
        }
        // The config file is this app's to repair, not the system's.
        #expect(Grant.Kind.configFile.settingsURL == nil)
    }

    // MARK: - The Apple-events probe

    /// Written as literals in the source with their Carbon names in comments, because
    /// `errAEEventWouldRequireUserConsent` is the value that separates "never asked"
    /// from "refused" and has been unavailable to Swift on and off. A build that lumped
    /// the two together would offer a Request button the system never answers.
    @Test("The Apple-events status codes map to distinguishable states")
    func automationStatusMapping() {
        #expect(PermissionAudit.interpretAutomation(0) == .granted)
        #expect(PermissionAudit.interpretAutomation(-1743) == .denied)
        #expect(PermissionAudit.interpretAutomation(-1744) == .notDetermined)
        // **Not** `.notDetermined`, which is what this returned and what made the row
        // lie. System Events is launched on demand and idle most of the time, so a
        // machine that *holds* the grant reported it missing whenever nothing had driven
        // a script recently — `doctor` said "not requested yet" while the app's panel
        // said "granted", purely because the agent had been scripting and the shell had
        // not. Unknown is the honest answer and is still not satisfied.
        #expect(PermissionAudit.interpretAutomation(-600) == .unknown)
        #expect(!PermissionAudit.interpretAutomation(-600).isSatisfied)
        #expect(PermissionAudit.interpretAutomation(-12345) == .unknown)
    }

    /// A row that cannot be answered has to say why, or "could not be determined" reads
    /// as a defect in the machine rather than as a target that happens to be asleep.
    @Test("An unanswerable Automation row carries its reason and a way out")
    func unknownAutomationExplainsItself() {
        let grant = Grant(
            kind: .automation, state: .unknown,
            detail: PermissionAudit.automationGrant().detail
        )
        // Only meaningful when the probe genuinely could not answer; when System Events
        // happens to be running there is nothing to explain.
        if PermissionAudit.automationGrant().state == .unknown {
            let detail = grant.detail ?? ""
            #expect(detail.contains("System Events"))
            #expect(!detail.lowercased().contains("denied"))
            #expect(detail.contains("openclicky grant"))
        }
    }

    // MARK: - Why grants vanish

    /// The account behind "my permissions keep disappearing". TCC keys an ad-hoc app's
    /// grants to its cdhash, which changes on every rebuild — three separate attempts to
    /// verify a fix in this project died on exactly that, each looking like the fix had
    /// failed.
    @Test("An unstable identity is explained rather than left as a mystery")
    func hostAdviceNamesTheRealCause() {
        let adHoc = HostIdentity(isBundled: true, bundleID: "com.openclicky.app", hasStableIdentity: false)
        #expect(adHoc.advice?.contains("ad-hoc") == true)

        let loose = HostIdentity(isBundled: false, bundleID: nil, hasStableIdentity: true)
        #expect(loose.advice?.contains("bundle") == true)

        let unknown = HostIdentity(isBundled: true, bundleID: "x", hasStableIdentity: nil)
        #expect(unknown.advice != nil)

        // Nothing to say about a properly signed bundle, and saying something anyway
        // would train the user to ignore the row.
        #expect(HostIdentity(isBundled: true, bundleID: "x", hasStableIdentity: true).advice == nil)
    }

    // MARK: - Reporting

    @Test("The report covers every grant and every rung")
    func reportIsComplete() {
        let text = audit(automation: .denied).report(mark: { $0 ? "ok" : "no" })
        for kind in Grant.Kind.allCases {
            #expect(text.contains(kind.title), "report omits \(kind.rawValue)")
        }
        for tier in Tier.allCases {
            #expect(text.contains(tier.label), "report omits \(tier.label)")
        }
        #expect(text.contains("Voice session"))
    }

    /// Two audits built from the same facts must compare equal however they were
    /// assembled, or a SwiftUI panel would redraw — and reorder its own rows — on every
    /// two-second poll.
    @Test("Rows are ordered by kind, not by the order they were probed in")
    func orderIsStable() {
        let forwards = PermissionAudit(grants: Grant.Kind.allCases.map {
            Grant(kind: $0, state: .granted)
        })
        let backwards = PermissionAudit(grants: Grant.Kind.allCases.reversed().map {
            Grant(kind: $0, state: .granted)
        })
        #expect(forwards == backwards)
        #expect(forwards.grants.map(\.kind) == Grant.Kind.allCases)
    }

    /// A grant nobody probed is missing, not granted — the same rule as `.unknown`.
    @Test("A grant absent from the audit reads as unknown")
    func absentGrantIsUnknown() {
        let partial = PermissionAudit(grants: [Grant(kind: .accessibility, state: .granted)])
        #expect(partial.state(of: .microphone) == .unknown)
        #expect(!partial.canHear)
    }

    // MARK: - The config file as a permission

    @Test("A widened config file reads as denied, carrying the fix")
    func exposedConfigIsReported() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-test-123456789", provider: "anthropic")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: config.url.path
        )

        let grant = PermissionAudit.configFileGrant(config: config)
        #expect(grant.state == .denied)
        #expect(grant.detail?.contains("chmod 600") == true)
    }

    @Test("A correctly protected config file is granted, with nothing to add")
    func protectedConfigIsGranted() throws {
        let config = isolatedConfig()
        defer { try? FileManager.default.removeItem(at: config.url.deletingLastPathComponent()) }
        try config.setKey("sk-test-123456789", provider: "anthropic")

        let grant = PermissionAudit.configFileGrant(config: config)
        #expect(grant.state == .granted)
        #expect(grant.detail == nil)
    }

    // MARK: - Whose grants these are

    /// The subject the rows were missing, and the confusion it caused: a screenshot from
    /// a shell failed with "could not create image from display" at the same moment the
    /// app's own panel reported Screen Recording granted. Both were right. TCC answers
    /// for a *process*, and a CLI's process is the terminal it was typed into — but
    /// nothing in either report said whose answer it was giving.
    @Test("A bundled app answers for itself; a CLI answers for its terminal")
    func principalNamesTheRightProcess() {
        #expect(HostIdentity.principal(
            isBundled: false, bundle: .main, environment: ["TERM_PROGRAM": "Apple_Terminal"]
        ) == "Terminal")
        #expect(HostIdentity.principal(
            isBundled: false, bundle: .main, environment: ["TERM_PROGRAM": "iTerm.app"]
        ) == "iTerm")
    }

    /// Naming the wrong application is worse than naming none: it sends someone to
    /// change a setting on an app that is not involved. The same rule
    /// `HostTerminal.bundleIdentifier` already follows for suppression.
    @Test("An unknown terminal is described, not guessed at")
    func unknownTerminalIsNotInvented() {
        for environment in [[:], ["TERM_PROGRAM": ""], ["TERM_PROGRAM": "something-new"]] {
            let named = HostIdentity.principal(
                isBundled: false, bundle: .main, environment: environment
            )
            #expect(named == "the terminal you ran this from")
        }
    }

    /// Every terminal this knows how to suppress must also be one it can name, or the
    /// advice falls back to "the terminal you ran this from" for a terminal the rest of
    /// the codebase identifies confidently.
    @Test("Every terminal with an identifier also has a name")
    func mapsAgree() {
        #expect(Set(HostTerminal.namesByTermProgram.keys)
            == Set(HostTerminal.bundleIDsByTermProgram.keys))
    }

    /// The whole point of naming it: the rows are a claim about a process, and a report
    /// that omits the subject invites exactly the comparison that looks like a bug.
    @Test("The report names its subject before making any claim")
    func reportNamesItsSubject() throws {
        let cli = PermissionAudit(
            grants: [Grant(kind: .screenRecording, state: .denied)],
            host: HostIdentity(isBundled: false, bundleID: nil,
                               hasStableIdentity: true, principal: "Terminal")
        )
        let text = cli.report()
        // Ahead of the first row, not in a footnote below them: the rows come first and
        // read as claims about OpenClicky, so a correction underneath arrives after the
        // wrong impression has already formed.
        let subject = try #require(text.range(of: "Terminal"))
        let firstRow = try #require(text.range(of: "Screen Recording"))
        #expect(subject.lowerBound < firstRow.lowerBound)

        // And the advice says the two surfaces disagreeing is expected, not a defect.
        let advice = try #require(cli.host.advice)
        #expect(advice.contains("Terminal"))
        #expect(advice.contains("OpenClicky.app"))
    }

    // MARK: - One prober

    /// The hazard `PermissionStatus` names in its own source: *two readings of one
    /// grant* is how a panel comes to say "granted" beside a session that cannot hear
    /// anything. Both types used to call the TCC APIs themselves; this holds them to one
    /// answer now that the narrow one is derived from the full one.
    @Test("The narrow status is a view onto the audit, never a second opinion")
    func statusAgreesWithTheAudit() {
        for screen in [GrantState.granted, .denied] {
            for access in [GrantState.granted, .denied] {
                for mic in [GrantState.granted, .denied, .notDetermined] {
                    let full = audit(accessibility: access, screenRecording: screen, microphone: mic)
                    let narrow = PermissionStatus.from(full)
                    #expect(narrow.screenRecording == full.grant(.screenRecording).isSatisfied)
                    #expect(narrow.accessibility == full.grant(.accessibility).isSatisfied)
                    #expect(narrow.microphone == full.canHear)
                    // And the two verdicts about the ladder cannot disagree either.
                    #expect(narrow.allGranted == full.isLadderComplete)
                }
            }
        }
    }

    /// The false *positive* that prompted this. `isReady` checked Accessibility and
    /// Screen Recording only, so `openclicky doctor && openclicky "open my calendar"`
    /// passed on a machine where AppleScript was denied — and the run then died on
    /// "osascript is not allowed to send keystrokes". Tier 1 is this project's
    /// differentiator; a readiness check that ignores its grant is checking the two
    /// tiers that matter least to most tasks.
    @Test("A machine that cannot run AppleScript is not ready for a tier-1 run")
    func automationGatesReadiness() {
        let denied = PermissionStatus.from(audit(automation: .denied))
        #expect(!denied.isReady(credentials: .working, upTo: .script))
        #expect(!denied.isReady(credentials: .working, upTo: .accessibility))
        #expect(!denied.isReady(credentials: .working, upTo: .pixels))
        // And the rule the other grants follow: a run capped below the tier that needs
        // it never reaches AppleScript, so demanding the grant would fail a machine that
        // is entirely ready for the run it is about to do.
        #expect(denied.isReady(credentials: .working, upTo: .shell))
    }

    /// The advice must not contradict itself. "Tiers 0 and 1 work without either" on a
    /// machine whose *Automation* grant is the missing one is the report telling the
    /// user the broken tier is fine.
    @Test("Advice names Automation, and stops promising the tier it just denied")
    func adviceCoversAutomation() throws {
        let denied = PermissionStatus.from(audit(automation: .denied))
        let advice = try #require(denied.advice(upTo: .script))
        #expect(advice.contains("Automation"))
        #expect(!advice.contains("Tiers 0 and 1"))
        #expect(advice.contains("openclicky grant"))

        // Still silent when the tier in play could not have used it.
        #expect(denied.advice(upTo: .shell) == nil)
    }

    /// The rule both types follow, stated once: a grant a run will never use is not a
    /// reason to call the machine unready. The microphone is the case that matters —
    /// every text run is one, and folding it in would fail `doctor && openclicky "…"` on
    /// a machine entirely ready for the run it is about to do.
    @Test("A missing microphone leaves the machine ready for a text run")
    func microphoneDoesNotBlockARun() {
        let deaf = PermissionStatus.from(audit(microphone: .denied))
        #expect(deaf.allGranted)
        #expect(deaf.isReady(credentials: .working))
        #expect(deaf.voiceAdvice != nil)
    }
}
