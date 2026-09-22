import Testing
import Foundation
@testable import OpenClickyKit

/// Bringing an app forward, and the three refusals that make it safe to do unasked.
///
/// None of this needs a window server. That is the point of the seams: the rules worth
/// having — an app the machine does not have is refused, our own surface is refused, and
/// an app that did not arrive is reported as not having arrived — are decidable from the
/// arguments, and a rule that can only be checked by launching Safari is a rule that
/// gets checked once.
@Suite("Activate app")
struct ActivateAppTests {

    private let safari = AppCatalogue.Entry(
        bundleIdentifier: "com.apple.Safari",
        name: "Safari",
        url: URL(fileURLWithPath: "/Applications/Safari.app"),
        isRunning: false
    )

    private var catalogue: AppCatalogue {
        AppCatalogue(entries: [safari], truncated: false)
    }

    /// Records whether the workspace was ever asked to do anything.
    private final class LaunchSpy: @unchecked Sendable {
        private(set) var launched: [String] = []
        var activate: @Sendable (AppCatalogue.Entry) async throws -> Void {
            { [self] entry in launched.append(entry.bundleIdentifier) }
        }
    }

    private func tool(
        frontmostAfter: String? = "com.apple.Safari",
        selfBundleIDs: [String] = [],
        spy: LaunchSpy = LaunchSpy()
    ) -> ActivateAppTool {
        let snapshot = catalogue
        return ActivateAppTool(
            selfBundleIDs: selfBundleIDs,
            catalogue: { snapshot },
            frontmost: { frontmostAfter },
            activate: spy.activate
        )
    }

    // MARK: - The classification, which is the safety argument

    /// Reaching `.focus` is proof the identifier was matched against an enumeration of
    /// this disk — `FocusChange.activate` takes a catalogue entry and nothing else can
    /// make one.
    @Test("An app this Mac has is a focus change")
    func knownAppIsFocus() {
        let risk = tool().risk(for: .object(["bundle_identifier": .string("com.apple.Safari")]))
        guard case let .focus(change) = risk else {
            Issue.record("a catalogued app was not classified as a focus change")
            return
        }
        #expect(change.identity == "activate:com.apple.Safari")
    }

    /// The whole of the other half. An identifier that was not enumerated gets no
    /// exemption from the prompt — it is an unexplained change like any other.
    @Test("An app this Mac does not have is a write, and prompts like one", arguments: [
        "com.example.Nonexistent", "", "../../etc/passwd",
    ])
    func unknownAppIsWrite(identifier: String) {
        let risk = tool().risk(for: .object(["bundle_identifier": .string(identifier)]))
        guard case .write = risk else {
            Issue.record("an app outside the catalogue was exempted from the gate")
            return
        }
    }

    @Test("A missing argument is a write, not a crash")
    func missingArgumentIsWrite() {
        let risk = tool().risk(for: .object([:]))
        guard case .write = risk else {
            Issue.record("a call with no app named was exempted from the gate")
            return
        }
    }

    /// A cold catalogue answers empty rather than blocking on the disk, so the call is
    /// gated *more* strictly. `risk(for:)` is synchronous and on the loop's path; it
    /// must never wait for a filesystem scan.
    @Test("An empty catalogue gates more strictly rather than stalling")
    func emptyCatalogueIsWrite() {
        let cold = ActivateAppTool(catalogue: { .empty }, frontmost: { nil })
        let risk = cold.risk(for: .object(["bundle_identifier": .string("com.apple.Safari")]))
        guard case .write = risk else {
            Issue.record("a cold catalogue exempted an unverified app from the gate")
            return
        }
    }

    // MARK: - Running it

    @Test("A catalogued app is brought forward and reported as frontmost")
    func activatesAndVerifies() async throws {
        let spy = LaunchSpy()
        let output = try await tool(spy: spy)
            .run(.object(["bundle_identifier": .string("com.apple.Safari")]))
        #expect(spy.launched == ["com.apple.Safari"])
        #expect(!output.isError)
        #expect(output.changeVerdict == .changed)
    }

    /// macOS activation is cooperative and can be refused or deferred. The one thing
    /// this must not do is claim a change it did not observe — `RunOutcome` counts an
    /// `.unchanged` as an observation, so a refused activation cannot be mistaken for
    /// work the run did.
    @Test("An app that never comes forward is reported as not having come forward")
    func refusedActivationIsHonest() async throws {
        let output = try await tool(frontmostAfter: "com.apple.Terminal")
            .run(.object(["bundle_identifier": .string("com.apple.Safari")]))
        #expect(output.changeVerdict == .unchanged,
                "an activation that did not land was reported as a change")
        #expect(!output.isError, "not arriving yet is a finding, not a failure")
    }

    @Test("An app this Mac does not have is refused without touching the workspace")
    func unknownAppIsNeverLaunched() async throws {
        let spy = LaunchSpy()
        let output = try await tool(spy: spy)
            .run(.object(["bundle_identifier": .string("com.example.Nonexistent")]))
        #expect(output.isError)
        #expect(spy.launched.isEmpty, "an app outside the catalogue was launched anyway")
    }

    /// Our own surface is not the user's. Switching to ourselves takes the screen away
    /// from the work rather than toward it, and would fight the focus the app hands back
    /// before a run starts.
    @Test("The agent refuses to bring itself to the front")
    func refusesSelf() async throws {
        let spy = LaunchSpy()
        let tool = ActivateAppTool(
            selfBundleIDs: ["com.apple.Safari"],
            catalogue: { catalogue },
            frontmost: { "com.apple.Safari" },
            activate: spy.activate
        )
        let output = try await tool.run(.object(["bundle_identifier": .string("com.apple.Safari")]))
        #expect(output.isError)
        #expect(spy.launched.isEmpty, "the agent switched to itself")
    }

    // MARK: - Where it sits

    /// Tier 0 is not a technicality. `NSWorkspace.openApplication` needs no TCC grant at
    /// all, so at tier 1 `reachableTier` would cap it out on a machine with no Automation
    /// grant — capping out the one capability that still works when nothing else does.
    @Test("It sits at the lowest tier, because it needs no grant")
    func tierIsZero() {
        #expect(ActivateAppTool().tier == .shell)
        #expect(Tier.forToolNamed("activate_app") == .shell,
                "a recorded session would report this tool's tier as unknown")
    }

    @Test("It is in the registry every surface uses")
    func isRegistered() {
        #expect(ToolRegistry.standard()["activate_app"] != nil)
        #expect(ToolRegistry.standard(maxTier: .shell)["activate_app"] != nil,
                "a tier-0 run could not bring an app forward")
    }
}
