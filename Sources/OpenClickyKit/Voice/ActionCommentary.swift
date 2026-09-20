import Foundation

/// Says what the agent is about to do, when the agent itself did not.
///
/// The system prompt has always asked a narrating model to say what it is doing before
/// it does it, and `AgentLoop` emits a turn's prose before that turn's tool calls, so
/// the ordering the feature needs has been there from the start. What was missing is
/// that **not every model writes any prose**. Read off a real session against
/// `gpt-4.1`, an acting turn is one content block:
///
///     {"role":"assistant","content":[{"type":"tool_use","name":"ax_capture",…}]}
///
/// No text. Anthropic's models narrate almost every turn; the OpenAI-compatible ones
/// routinely answer a decision to act with the call alone. So a spoken session against
/// the configured default said its opener, went silent for the whole run, and delivered
/// a paragraph at the end — which is a progress bar with no bar, and is what "it isn't
/// talking while it works" actually was.
///
/// This is the floor under that, and the boundary it keeps is the important part:
///
/// - It describes **the call we are about to make**, which this process knows for
///   certain because it is the one making it.
/// - It never describes **what was found or what happened**, which is the model's
///   account of the user's machine to give. `Narration` carries that and invents
///   nothing; a commentary that said "no updates available" would be the application
///   putting a claim about someone's Mac into its own mouth, which is a run reporting
///   success it did not earn one surface along.
///
/// It also never reads the arguments out. A tool's arguments carry content the agent
/// just read off the screen — a filename, a form field, a line of someone's script —
/// and a listener gets nothing from hearing a shell command spelled out that they would
/// not get from "running a command".
public struct ActionCommentary: Sendable, Equatable {

    /// What to say for each tool, or nothing where saying anything is worse.
    ///
    /// Present tense and a handful of words, because this is spoken *underneath* an
    /// action that is already happening — anything longer is still playing when the
    /// next one starts.
    private static let phrases: [String: String] = [
        "shell": "Running a command.",
        "app_script": "Asking the app to do that.",
        "run_shortcut": "Running a shortcut.",
        "ax_capture": "Reading the screen.",
        "ax_press": "Pressing that.",
        "ax_set_value": "Filling that in.",
        "click": "Clicking.",
        "drag": "Dragging that across.",
        "key": "Sending a keystroke.",
        "type": "Typing.",
        "scroll": "Scrolling.",
        "screenshot": "Taking a look.",
        "zoom": "Looking closer.",
        "read_file": "Reading a file.",
        "write_file": "Saving that.",
        // Deliberately silent. `wait` exists so a UI can settle, and announcing a pause
        // fills the silence it was asked for. `ask_user` has its own question, spoken by
        // the session — saying "asking you something" in front of it is a preamble to a
        // sentence that is already on its way.
        "wait": "",
        "ask_user": "",
    ]

    /// Whether this turn has already been narrated by the model itself.
    private var turnWasNarrated = false
    /// The last thing said, so a turn of five clicks is not five identical sentences.
    private var lastSpoken: String?

    public init() {}

    /// A new turn began. Called for `.thinking`, which the loop emits per turn.
    public mutating func turnBegan() {
        turnWasNarrated = false
    }

    /// The model narrated this turn in its own words, and they were said out loud.
    ///
    /// Only when they were actually spoken. Prose that `Narration` reduced to nothing —
    /// a turn that was entirely a code block, say — left the listener with the same
    /// silence as no prose at all, and treating it as narration would suppress the one
    /// thing that would have filled it.
    public mutating func narrated() {
        turnWasNarrated = true
        // The model's own sentence resets the ear: whatever was said before it is far
        // enough back that repeating a phrase no longer sounds like a stutter.
        lastSpoken = nil
    }

    /// What to say as a tool starts, or nil to stay quiet.
    ///
    /// - Returns: nil when the model has already spoken for this turn, when the tool is
    ///   one that is better announced by silence, or when it would repeat the sentence
    ///   just said.
    public mutating func announcing(tool: String) -> String? {
        guard !turnWasNarrated else { return nil }
        guard let phrase = Self.phrases[tool], !phrase.isEmpty else { return nil }
        // Five clicks in a turn are one action to a listener. Saying "Clicking." five
        // times is how a voice stops being listened to.
        guard phrase != lastSpoken else { return nil }
        lastSpoken = phrase
        return phrase
    }

    /// Every tool this knows how to announce. For tests, so a tool added without a
    /// phrase is found here rather than by a listener hearing nothing.
    public static var describedTools: Set<String> {
        Set(phrases.filter { !$0.value.isEmpty }.keys)
    }

    /// Tools deliberately announced by saying nothing.
    public static var silentTools: Set<String> {
        Set(phrases.filter { $0.value.isEmpty }.keys)
    }
}
