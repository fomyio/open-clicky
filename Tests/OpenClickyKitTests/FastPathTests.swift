import Testing
import Foundation
@testable import OpenClickyKit

/// The one place a classifier is allowed to cause an action, and the rules that bound it.
///
/// `TurnReading`'s header states the rule the rest of the voice layer keeps: a reading
/// may make the session more cautious and may never make it act. This is the exception,
/// so every clause that narrows it is tested separately — and all of them are pure, so
/// none of them depends on a vendor answering the way the documentation says.
@Suite("Fast path")
struct FastPathTests {

    private func entry(
        _ identifier: String, _ name: String,
        isRunning: Bool = false, isAmbiguous: Bool = false
    ) -> AppCatalogue.Entry {
        AppCatalogue.Entry(
            bundleIdentifier: identifier, name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            isRunning: isRunning, isAmbiguous: isAmbiguous
        )
    }

    private var options: FastPath.Options {
        FastPath.Options(
            apps: [entry("com.apple.Safari", "Safari"), entry("com.apple.Notes", "Notes")],
            truncated: false
        )
    }

    private func resolve(
        _ chosen: String, confidence: Double = 0.99, margin: Double? = nil,
        options: FastPath.Options? = nil
    ) -> FastPath.Action {
        FastPath.resolve(
            chosen: chosen, confidence: confidence, margin: margin,
            options: options ?? self.options
        )
    }

    // MARK: - The option name is the action

    @Test("An option name round-trips to the action it names")
    func namesRoundTrip() {
        let actions: [FastPath.Action] = [
            .none, .model, .activate(bundleIdentifier: "com.apple.Safari"),
        ]
        for action in actions {
            #expect(FastPath.Action.named(action.name) == action)
        }
    }

    /// One string serves as the wire option *and* the key an action is remembered by
    /// once done. A second mapping is a second thing to keep in step.
    @Test("The identity an action is remembered by is the name it was chosen as")
    func identityIsTheName() {
        let safari = FastPath.Action.activate(bundleIdentifier: "com.apple.Safari")
        let notes = FastPath.Action.activate(bundleIdentifier: "com.apple.Notes")
        #expect(safari.name == "activate:com.apple.Safari")
        #expect(safari.name != notes.name)
    }

    /// A name this build cannot execute must read as "ask the model", never as a guess.
    /// Anything else is a silent no-op.
    @Test("A name this build cannot execute goes to the model", arguments: [
        "", "activate:", "media:play_pause", "window:minimise", "nonsense", "ACTIVATE:x",
    ])
    func unknownNamesGoToTheModel(raw: String) {
        #expect(FastPath.Action.named(raw) == .model)
    }

    // MARK: - The two options that must always be offered

    /// Without them a `Choice` has no way to say "not one of these" and is forced to
    /// name an app for "what's the weather" — a question with no right answer in it.
    @Test("Doing nothing and asking the model are always on the list")
    func escapeHatchesAreAlwaysOffered() {
        #expect(options.criteria["none"] != nil)
        #expect(options.criteria["llm"] != nil)
        #expect(FastPath.Options.empty.criteria["none"] != nil,
                "an empty catalogue left the classifier with no way to decline")
        #expect(FastPath.Options.empty.criteria["llm"] != nil)
    }

    @Test("Every offered app is described by what it is and whether it is running")
    func appsAreDescribed() {
        let criteria = FastPath.Options(
            apps: [entry("com.apple.Safari", "Safari", isRunning: true)], truncated: false
        ).criteria
        let described = criteria["activate:com.apple.Safari"] ?? ""
        #expect(described.contains("Safari"))
        #expect(described.contains("running"),
                "an option could not be told apart from an identical one not on screen")
    }

    // MARK: - What may be acted on

    @Test("A confident pick of an offered app is acted on")
    func aConfidentPickActs() {
        #expect(resolve("activate:com.apple.Safari")
                == .activate(bundleIdentifier: "com.apple.Safari"))
    }

    @Test("Doing nothing and asking the model pass through untouched")
    func nonActionsPassThrough() {
        #expect(resolve("none") == .none)
        #expect(resolve("llm") == .model)
        // Even at low confidence: declining to act needs no confidence at all.
        #expect(resolve("none", confidence: 0.1) == .none)
    }

    /// Declining wrongly costs one model round trip — the behaviour that shipped before
    /// any of this. Acting wrongly does something to the machine nobody asked for.
    @Test("An unsure pick goes to the model", arguments: [0.0, 0.5, 0.89])
    func unsurePicksDeferToTheModel(confidence: Double) {
        #expect(resolve("activate:com.apple.Safari", confidence: confidence) == .model)
    }

    /// A `Choice` should not be able to return an option it was not given, so reaching
    /// this means a version skew — and the safe reading of an answer to a question we
    /// did not ask is that there is no answer.
    @Test("An app that was never offered is never acted on")
    func unofferedAppsAreRefused() {
        #expect(resolve("activate:com.example.Nonexistent") == .model)
    }

    /// Two builds of one app. The catalogue collapsed them at build time precisely so
    /// this does not need a probability margin to notice.
    @Test("An app with a rival by the same name is left to the model")
    func ambiguousAppsAreRefused() {
        let rivals = FastPath.Options(
            apps: [entry("com.google.Chrome", "Google Chrome", isAmbiguous: true)],
            truncated: false
        )
        #expect(resolve("activate:com.google.Chrome", options: rivals) == .model)
    }

    /// A calibrated 0.91 spread thinly over two near-identical options is a coin flip
    /// wearing a decimal point.
    @Test("A win by a narrow margin is left to the model")
    func narrowMarginsAreRefused() {
        #expect(resolve("activate:com.apple.Safari", margin: 0.05) == .model)
        #expect(resolve("activate:com.apple.Safari", margin: 0.5)
                == .activate(bundleIdentifier: "com.apple.Safari"))
    }

    /// An absent distribution is not a reason to act on less evidence — it is simply
    /// one fewer check, with the others still standing.
    @Test("A missing distribution neither blocks nor excuses")
    func absentMarginIsNotDecisive() {
        #expect(resolve("activate:com.apple.Safari", margin: nil)
                == .activate(bundleIdentifier: "com.apple.Safari"))
        #expect(resolve("activate:com.apple.Safari", confidence: 0.2, margin: nil) == .model)
    }

    // MARK: - Truncation

    /// The list was cut, so the right answer may not have been on it — and a `Choice`
    /// names the closest thing it *was* shown. This is how "open Fantastical" launches
    /// Calendar.
    @Test("When the list was cut, an app that is not on screen is left to the model")
    func truncationRefusesAppsNotRunning() {
        let cut = FastPath.Options(
            apps: [entry("com.apple.Notes", "Notes")], truncated: true
        )
        #expect(resolve("activate:com.apple.Notes", options: cut) == .model)
    }

    /// A running app is still safe: it is on screen, it is what somebody looking at
    /// their machine means, and it is never what truncation removes.
    @Test("When the list was cut, an app on screen is still acted on")
    func truncationStillTrustsRunningApps() {
        let cut = FastPath.Options(
            apps: [entry("com.apple.Notes", "Notes", isRunning: true)], truncated: true
        )
        #expect(resolve("activate:com.apple.Notes", options: cut)
                == .activate(bundleIdentifier: "com.apple.Notes"))
    }

    // MARK: - What it takes to skip the model entirely

    private func reading(
        action: FastPath.Action = .activate(bundleIdentifier: "com.apple.Safari"),
        addressed: Double = 0.99, complete: Double = 0.99
    ) -> TurnReading {
        TurnReading(
            utterance: "open Safari", addressed: addressed, complete: complete,
            halt: 0.01, intent: .instruction, intentConfidence: 0.9, action: action
        )
    }

    @Test("A finished instruction meant for us, naming an action, needs no model")
    func aClearTurnSkipsTheModel() {
        #expect(reading().canRunWithoutAModel)
    }

    /// The microphone hears the whole room, and every term of this guard is one of the
    /// ways a sentence can fail to be a request to us.
    @Test("A remark meant for somebody else is never acted on")
    func anOverheardTurnNeedsNoAction() {
        #expect(!reading(addressed: 0.02).canRunWithoutAModel,
                "something said across the room ran on the user's Mac")
    }

    /// "Open Safari" reads complete at word two. "Open Safari and then check my—" does
    /// not, and that single term is what stops one sentence becoming two runs.
    @Test("Half a sentence is never acted on")
    func anUnfinishedTurnNeedsNoAction() {
        #expect(!reading(complete: 0.05).canRunWithoutAModel,
                "the first half of a sentence was carried out on its own")
    }

    @Test("A turn with nothing to do, or work for the model, skips nothing")
    func nonActionsNeverSkipTheModel() {
        #expect(!reading(action: .none).canRunWithoutAModel)
        #expect(!reading(action: .model).canRunWithoutAModel)
    }

    // MARK: - The thresholds

    /// Pinned so that loosening one is a deliberate edit rather than a drift.
    @Test("Acting needs more evidence than declining does")
    func thresholdsLeanTowardsTheModel() {
        #expect(FastPath.confidenceFloor >= 0.9,
                "the bar for acting without a model was lowered")
        #expect(FastPath.marginFloor > 0)
    }
}
