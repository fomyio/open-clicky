import Testing
@testable import OpenClickyKit

/// A spoken run against the configured default said its opener, went silent for the
/// whole run, and delivered a paragraph at the end. Not because the ordering was wrong —
/// the loop emits a turn's prose before that turn's tool calls, and the prompt asks for
/// it — but because `gpt-4.1` answers a decision to act with the tool call alone. There
/// was no prose to say.
@Suite("Action commentary")
struct ActionCommentaryTests {

    @Test("A silent turn is described by the action it is about to take")
    func silentTurnsAreAnnounced() {
        var commentary = ActionCommentary()
        commentary.turnBegan()
        #expect(commentary.announcing(tool: "shell") == "Running a command.")
    }

    /// The model's own words are better than ours: they say what it is doing *here*,
    /// and ours can only say what kind of thing it is. So ours is a floor, not a chorus.
    @Test("A turn the model narrated is left alone")
    func narratedTurnsStaySilent() {
        var commentary = ActionCommentary()
        commentary.turnBegan()
        commentary.narrated()
        #expect(commentary.announcing(tool: "shell") == nil)
        #expect(commentary.announcing(tool: "click") == nil)
    }

    @Test("The floor comes back on the next turn")
    func theFloorReturnsEachTurn() {
        var commentary = ActionCommentary()
        commentary.turnBegan()
        commentary.narrated()
        #expect(commentary.announcing(tool: "shell") == nil)

        commentary.turnBegan()
        #expect(commentary.announcing(tool: "shell") == "Running a command.")
    }

    /// Five clicks in a turn are one action to a listener. Saying "Clicking." five
    /// times is how a voice stops being listened to.
    @Test("A repeated action is said once, not once per call")
    func repeatsAreSuppressed() {
        var commentary = ActionCommentary()
        commentary.turnBegan()
        #expect(commentary.announcing(tool: "click") == "Clicking.")
        #expect(commentary.announcing(tool: "click") == nil)
        #expect(commentary.announcing(tool: "click") == nil)
        // A different action is still worth saying.
        #expect(commentary.announcing(tool: "type") == "Typing.")
        // And the first one is again, now that it is not a stutter.
        #expect(commentary.announcing(tool: "click") == "Clicking.")
    }

    /// `wait` exists so a UI can settle; announcing a pause fills the silence it was
    /// asked for. `ask_user` has its own question, spoken by the session — a preamble in
    /// front of a sentence already on its way is just a longer wait for it.
    @Test("Some actions are announced by saying nothing", arguments: ["wait", "ask_user"])
    func deliberatelySilentTools(tool: String) {
        var commentary = ActionCommentary()
        commentary.turnBegan()
        #expect(commentary.announcing(tool: tool) == nil)
    }

    @Test("A tool this build does not know is not guessed at")
    func unknownToolsSayNothing() {
        var commentary = ActionCommentary()
        commentary.turnBegan()
        #expect(commentary.announcing(tool: "teleport") == nil)
        #expect(commentary.announcing(tool: "") == nil)
    }

    /// A tool added without a phrase is a tool the listener hears nothing for, and the
    /// only symptom is silence in the middle of a run — which is the exact failure this
    /// type exists to end. Found here instead.
    @Test("Every tool in the registry is either described or deliberately silent")
    func everyToolIsAccountedFor() {
        let known = ActionCommentary.describedTools.union(ActionCommentary.silentTools)
        let registry = ToolRegistry.standard()
        for name in registry.ordered.map(\.name) {
            #expect(known.contains(name), "\(name) has no spoken description")
        }
    }

    /// It describes the call we are about to make, which this process knows for certain.
    /// It never describes what was found — that is the model's account of the user's
    /// machine, and a commentary that gave one would be a run claiming an outcome it
    /// did not earn, one surface along.
    @Test("No phrase claims an outcome")
    func phrasesClaimNothing() {
        let outcomes = [
            "found", "no updates", "done", "finished", "succeeded", "failed",
            "worked", "installed", "up to date", "available",
        ]
        var commentary = ActionCommentary()
        for tool in ActionCommentary.describedTools {
            commentary.turnBegan()
            let phrase = (commentary.announcing(tool: tool) ?? "").lowercased()
            #expect(!phrase.isEmpty)
            for outcome in outcomes {
                #expect(!phrase.contains(outcome), "\(phrase) claims an outcome")
            }
        }
    }

    /// Spoken underneath an action that is already happening. Anything longer is still
    /// playing when the next one starts.
    @Test("Every phrase is short enough to fit under the action it describes")
    func phrasesAreShort() {
        var commentary = ActionCommentary()
        for tool in ActionCommentary.describedTools {
            commentary.turnBegan()
            let phrase = commentary.announcing(tool: tool) ?? ""
            #expect(phrase.count <= 32, "\(phrase)")
        }
    }
}
