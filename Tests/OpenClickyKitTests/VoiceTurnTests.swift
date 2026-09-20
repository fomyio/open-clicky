import Testing
@testable import OpenClickyKit

/// An endpointer answers a question about silence. That is not the question. "Can you
/// check for me the" was followed by a pause well past any threshold anyone would set,
/// and it is plainly not a finished instruction — the agent answered it anyway, because
/// silence was the only evidence it had.
@Suite("Was that the end of a sentence")
struct VoiceTurnTests {

    @Test("A dangling determiner is somebody still talking", arguments: [
        "can you check for me the",
        "open the",
        "what is my",
        "close all of",
        "show me this",
        "tell me about",
        "read the file and",
        "set the volume to fifty and",
    ])
    func danglingWordsAreUnfinished(spoken: String) {
        #expect(VoiceTurn.seemsUnfinished(spoken))
    }

    /// The constraint that keeps this narrow. English particles end plenty of complete
    /// instructions, so every preposition that doubles as one is left out — being wrong
    /// here delays an instruction that was ready, which is the direction that costs
    /// something.
    @Test("A phrasal particle does not make an instruction unfinished", arguments: [
        "turn it on", "turn the lights off", "wake it up", "shut it down",
        "log me in", "sign me out", "bring it back", "read it over",
        "put that away", "check for updates", "look it up",
    ])
    func particlesAreNotDangling(spoken: String) {
        #expect(!VoiceTurn.seemsUnfinished(spoken))
    }

    @Test("An ordinary instruction is finished", arguments: [
        "check if I have any pending updates on my macOS",
        "open Safari",
        "what voices does Siri have",
        "stop",
        "close the window",
        "run the tests",
        // Wh-questions land on an auxiliary, and they are the shape this feature exists
        // for. Holding each of them for a grace would make the common case sluggish.
        "what voices does Siri have",
        "tell me what it does",
        "show me what there is",
        "check what updates I have",
    ])
    func ordinaryInstructionsAreFinished(spoken: String) {
        #expect(!VoiceTurn.seemsUnfinished(spoken))
    }

    /// Someone choosing their words. Acting on it would be acting on a noise, and the
    /// sentence it was the front of is still coming.
    @Test("Hesitation is unfinished", arguments: ["um", "uh", "er", "hmm", "so", "um uh"])
    func hesitationIsUnfinished(spoken: String) {
        #expect(VoiceTurn.seemsUnfinished(spoken))
    }

    @Test("Hesitation inside a finished sentence does not hold it up")
    func hesitationMidSentenceIsFine() {
        #expect(!VoiceTurn.seemsUnfinished("um open Safari"))
        #expect(!VoiceTurn.seemsUnfinished("so check for updates"))
    }

    /// Punctuation and casing are the transcriber's choices, not the speaker's.
    @Test("The reading survives the transcriber's formatting")
    func normalisationApplies() {
        #expect(VoiceTurn.seemsUnfinished("Can you check for me, the…"))
        #expect(VoiceTurn.seemsUnfinished("  THE  "))
        #expect(!VoiceTurn.seemsUnfinished("Open Safari."))
    }

    @Test("Nothing at all is not a held turn")
    func emptyIsNotUnfinished() {
        #expect(!VoiceTurn.seemsUnfinished(""))
        #expect(!VoiceTurn.seemsUnfinished("   "))
    }
}
