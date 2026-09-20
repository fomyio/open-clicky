import Foundation

/// The short things a listener needs to hear while nothing is happening yet.
///
/// A typed session shows "Thinking…" the instant Return is pressed. A spoken one had
/// nothing: the user finished a sentence and the machine went silent while a planner
/// ran — **twenty-five seconds** of it in the session this was written from — and
/// silence on a voice channel does not read as "working", it reads as "it did not hear
/// me". So the sentence is started over, which barges in and cancels the run that was
/// about to answer it, and the session never gets anywhere.
///
/// Two kinds, because the two silences are different. An *opener* is the receipt for
/// having heard you and goes out before the first byte is sent. A *hold* is for a wait
/// that outlasts the opener, and says only that the wait is still going.
///
/// **Nothing here makes a claim about the machine.** Every line is about this
/// conversation — heard you, still going — and never about what was found or done. That
/// is the same rule `Narration` keeps: the agent's account of the user's Mac is the
/// model's to give, and a filler that said "let me check your settings" would be the
/// application putting a statement about the user's machine into its own mouth, one
/// surface along from a run reporting success it did not earn.
///
/// Indexed rather than random so a test can read what will be said, and so the same
/// phrase does not come up twice running — which is the tell that turns an assistant
/// back into a recording.
public enum VoiceFiller {

    /// Said the moment a turn is understood, before anything is sent anywhere.
    ///
    /// Short on purpose: this is spoken into the gap before the agent's own first
    /// sentence, and an opener still playing when the narration arrives delays the only
    /// part with information in it. Two or three words is a receipt; a sentence is an
    /// interruption of its own.
    static let openers = [
        "Sure, one moment.",
        "Okay, let me take a look.",
        "Right, give me a second.",
        "Got it, checking now.",
        "On it.",
        "Sure thing, one second.",
    ]

    /// Said when the wait has outlasted the opener and there is still nothing to report.
    ///
    /// Deliberately contentless. The agent has not come back yet, so anything more
    /// specific than "still going" would be invented — and the one thing worse than a
    /// silent assistant is one that narrates progress it has not made.
    static let holds = [
        "Still working on it.",
        "Give me a moment.",
        "Nearly there.",
        "Still going.",
    ]

    /// How long a wait may go unremarked before it needs saying again.
    ///
    /// Seven seconds after the opener, and every seven after that. Long enough that an
    /// ordinary turn — which answers in two or three — is never interrupted by one, and
    /// short enough that the twenty-five-second planner wait this was written from is
    /// broken up rather than being one unbroken silence.
    public static let patience: TimeInterval = 7

    /// The opener for a turn, by the count of turns this session has taken.
    public static func opener(turn: Int) -> String { openers.cycled(turn) }

    /// The next thing to say while a wait continues, by how many have already been said.
    public static func hold(after spoken: Int) -> String { holds.cycled(spoken) }
}

private extension Array where Element == String {
    /// Wraps, and tolerates a negative index — the counter behind it is a turn count
    /// that a long session may overflow, and a crash is not the right answer to being
    /// talked to for a very long time.
    func cycled(_ index: Int) -> String {
        precondition(!isEmpty)
        let wrapped = index % count
        return self[wrapped < 0 ? wrapped + count : wrapped]
    }
}
