import Foundation

/// Whether a pause was the end of a sentence, or somebody thinking.
///
/// An endpointer answers a question about *silence*: has it been quiet for N
/// milliseconds. That is not the question. "Can you check for me the" is followed by a
/// four-second pause in the session this was written from — well past any endpointing
/// threshold anyone would set — and it is plainly not a finished instruction. The agent
/// answered it anyway, because silence was the only evidence it had.
///
/// So this reads the *words*, which is the evidence the endpointer does not have. It
/// decides one thing only: whether to give the speaker a few more seconds before taking
/// the floor. It cannot cause a turn to be lost — the settle timer submits regardless
/// once the grace expires — so the worst case of being wrong is a short wait, and the
/// best case is not being interrupted mid-thought.
///
/// **Deliberately narrow.** A word is listed only where a sentence ending on it is
/// almost certainly unfinished. English particles make that a real constraint: "turn it
/// **on**", "wake it **up**", "log **in**", "shut it **down**" all end on prepositions
/// and all are complete instructions, so the prepositions that double as particles are
/// left out entirely. Being wrong in that direction costs nothing; being wrong in the
/// other direction delays an instruction that was ready.
public enum VoiceTurn {

    /// Words that almost never end an instruction.
    ///
    /// Articles and determiners open a noun phrase that has not arrived; dangling
    /// conjunctions join a clause that has not arrived. Neither is a plausible last
    /// word for something somebody meant to say.
    private static let dangling: Set<String> = [
        // Articles and determiners — the most common of these by far, and the one the
        // original session log actually ended on.
        "a", "an", "the",
        "my", "your", "our", "their", "his", "her", "its",
        "this", "these", "those", "some", "any", "every", "another",
        // Conjunctions joining a clause that has not been said yet.
        "and", "or", "plus", "versus",
        // Prepositions that are not also phrasal-verb particles. "on", "off", "up",
        // "down", "in", "out", "over", "back", "through" and "away" are all missing on
        // purpose: each ends a perfectly complete instruction.
        "of", "with", "from", "about", "into", "onto", "between", "including",
    ]

    // Auxiliaries were here and had to come out. "Is", "are", "have", "does" and the
    // rest all double as main verbs, and the shape they most often end is a question —
    // "what voices does Siri **have**", "tell me what it **does**", "show me what
    // there **is**". Those are exactly the requests this feature exists for, and
    // holding each of them for a three-second grace would make the common case the
    // sluggish one. Caught by this file's own tests, not in the field.

    /// Noises people make while deciding what to say next.
    ///
    /// A turn that is *only* these is not an instruction at all, and one that ends on
    /// them is someone still choosing their words.
    private static let thinking: Set<String> = [
        "um", "uh", "er", "erm", "hmm", "mm", "eh", "like", "so",
    ]

    /// Whether the speaker sounds like they are still mid-sentence.
    public static func seemsUnfinished(_ spoken: String) -> Bool {
        let words = VoiceApproval.normalize(spoken).split(separator: " ").map(String.init)
        guard let last = words.last else { return false }
        if dangling.contains(last) || thinking.contains(last) { return true }
        // Nothing but hesitation. Submitting it would ask the agent to act on a noise,
        // and the sentence it was the front of is still coming.
        return words.allSatisfy(thinking.contains)
    }
}
