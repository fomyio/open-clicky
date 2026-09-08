import Testing
import Foundation
@testable import OpenClickyKit

/// The first thing the model reads, and for a while the first thing it read was wrong.
///
/// A recorded session in which the user asked for the VS Code command palette opened
/// with `frontmost app: OpenClicky (com.openclicky.app)`, because the probe reads the
/// live frontmost application and the overlay was in front of it. The model was being
/// told, in the opening line of the opening turn, that the user works in OpenClicky —
/// which is never true and never useful.
@Suite("The environment block names the app the user meant")
struct ContextProbeTests {

    private func probe(
        frontmostApp: String = "OpenClicky",
        bundleIdentifier: String? = "com.openclicky.app",
        windowTitle: String? = nil,
        summonedFrom: SummonedApp? = nil
    ) -> ContextProbe {
        ContextProbe(
            frontmostApp: frontmostApp,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            displays: ["display 0: 1512×982 pt (main)"],
            timestamp: Date(timeIntervalSince1970: 0),
            summonedFrom: summonedFrom
        )
    }

    @Test("The remembered app is what the block names")
    func namesTheRememberedApp() {
        let rendered = probe(summonedFrom: SummonedApp(
            name: "Code", bundleIdentifier: "com.microsoft.VSCode"
        )).rendered

        #expect(rendered.contains("the user was working in: Code (com.microsoft.VSCode)"))
    }

    /// The whole point. Naming both apps would still open the block by telling the
    /// model the user is in OpenClicky, and leave it to guess which of the two lines
    /// it is meant to act on.
    @Test("The live frontmost app is not named beside it")
    func theOverlayIsNotNamedBesideIt() {
        let rendered = probe(summonedFrom: SummonedApp(
            name: "Code", bundleIdentifier: "com.microsoft.VSCode"
        )).rendered

        #expect(!rendered.contains("com.openclicky.app"),
                "the recorded failure, still in the block: \(rendered)")
        #expect(!rendered.contains("frontmost app:"))
    }

    /// The CLI has no overlay in front of it: its frontmost app really is the user's
    /// terminal, and the probe must go on saying so.
    @Test("With nothing remembered, the block reports the live frontmost app")
    func fallsBackToLive() {
        let rendered = probe(
            frontmostApp: "Terminal", bundleIdentifier: "com.apple.Terminal"
        ).rendered

        #expect(rendered.contains("frontmost app: Terminal (com.apple.Terminal)"))
        #expect(!rendered.contains("the user was working in"))
    }

    @Test("A summon from OpenClicky itself is not remembered")
    func ourOwnBundleIsNotRemembered() {
        #expect(SummonedApp.remembered(
            name: "OpenClicky",
            bundleIdentifier: "com.openclicky.app",
            ownBundleIdentifiers: ["com.openclicky.app"]
        ) == nil)
    }

    /// Identifiers are compared case-insensitively everywhere else in this project,
    /// and for the same reason: one capital is all it takes for a check to stop
    /// matching the thing it was written to match.
    @Test("Our own bundle is recognised whatever its case")
    func ourOwnBundleIsRecognisedCaseInsensitively() {
        #expect(SummonedApp.remembered(
            name: "OpenClicky",
            bundleIdentifier: "com.OpenClicky.App",
            ownBundleIdentifiers: ["com.openclicky.app"]
        ) == nil)
    }

    @Test("An app with no name is not remembered")
    func namelessAppIsNotRemembered() {
        #expect(SummonedApp.remembered(
            name: nil, bundleIdentifier: "com.example.daemon", ownBundleIdentifiers: []
        ) == nil)
        #expect(SummonedApp.remembered(
            name: "   ", bundleIdentifier: "com.example.daemon", ownBundleIdentifiers: []
        ) == nil)
    }

    @Test("An ordinary app is remembered whole")
    func ordinaryAppIsRemembered() {
        let remembered = SummonedApp.remembered(
            name: "Code",
            bundleIdentifier: "com.microsoft.VSCode",
            ownBundleIdentifiers: ["com.openclicky.app"]
        )
        #expect(remembered == SummonedApp(
            name: "Code", bundleIdentifier: "com.microsoft.VSCode"
        ))
    }

    /// Nothing remembered and nothing to say: the block falls back to the live reading
    /// rather than inventing a line.
    @Test("Nil says nothing rather than something false")
    func nilSaysNothing() {
        let rendered = probe(summonedFrom: nil).rendered
        #expect(!rendered.contains("the user was working in"))
    }

    @Test("Remembering nothing clears what was remembered before")
    func memoryIsClearedByNil() {
        let memory = SummonedApp.Memory()
        memory.remember(SummonedApp(name: "Code", bundleIdentifier: "com.microsoft.VSCode"))
        #expect(memory.current?.name == "Code")

        memory.remember(nil)
        #expect(memory.current == nil)
    }

    /// The hotkey pressed while the overlay is already up, "New conversation" from the
    /// overlay's own button, the panel left on screen by a finished task: in all three
    /// the frontmost application is us, and in none of them has the app the user is
    /// working in changed. Clearing here would throw away the correct answer and hand
    /// the probe back to its live reading — which is the recorded line this whole type
    /// exists to remove.
    @Test("A summon from our own overlay keeps the app already remembered")
    func aSelfSummonKeepsThePreviousApp() {
        let memory = SummonedApp.Memory()
        memory.rememberSummon(
            from: "Code",
            bundleIdentifier: "com.microsoft.VSCode",
            ownBundleIdentifiers: ["com.openclicky.app"]
        )

        let arrived = memory.rememberSummon(
            from: "OpenClicky",
            bundleIdentifier: "com.openclicky.app",
            ownBundleIdentifiers: ["com.openclicky.app"]
        )

        #expect(arrived == false, "our own overlay is not somewhere the user works")
        #expect(memory.current?.name == "Code", "the answer was thrown away")
    }

    @Test("A summon from a different app replaces what was remembered")
    func aSummonFromElsewhereReplacesIt() {
        let memory = SummonedApp.Memory()
        memory.rememberSummon(
            from: "Code",
            bundleIdentifier: "com.microsoft.VSCode",
            ownBundleIdentifiers: ["com.openclicky.app"]
        )

        let arrived = memory.rememberSummon(
            from: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            ownBundleIdentifiers: ["com.openclicky.app"]
        )

        #expect(arrived)
        #expect(memory.current == SummonedApp(
            name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"
        ))
    }
}
