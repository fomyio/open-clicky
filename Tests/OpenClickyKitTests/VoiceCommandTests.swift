import Testing
@testable import OpenClickyKit

/// The one phrase everybody reaches for when they want it to stop was the one phrase
/// that made it start again: barge-in cancelled the run, the words arrived, and "stop"
/// was submitted as a fresh instruction for the agent to interpret.
@Suite("Spoken commands about the session")
struct VoiceCommandTests {

    @Test("A bare halt is read as one", arguments: [
        "stop", "Stop.", "STOP", "stop it", "stop that", "please stop", "stop please",
        "cancel", "cancel that", "cancel it", "never mind", "Never mind!", "nevermind",
        "forget it", "forget that", "abort", "quit", "halt",
        "be quiet", "quiet", "shut up", "that's enough", "thats enough", "enough",
    ])
    func haltsAreRecognised(spoken: String) {
        #expect(VoiceCommand.read(spoken) == .halt)
    }

    /// The rule that keeps this from eating real work. "Stop the music" is an
    /// instruction about a music player, and a matcher that looked for a halt *inside*
    /// a sentence would silently swallow it — a failure the user could only diagnose by
    /// noticing that one particular kind of request never worked.
    @Test("A halt with anything else attached is an instruction", arguments: [
        "stop the music", "stop sharing my screen", "cancel my 3pm meeting",
        "cancel the download in Safari", "quit Photoshop", "quit all my apps",
        "never mind the calendar, open Mail", "tell them to stop", "abort the upload",
        "forget it and open Safari",
    ])
    func haltsInsideSentencesAreNot(spoken: String) {
        #expect(VoiceCommand.read(spoken) == .instruction)
    }

    /// Said mid-instruction, while thinking. Cancelling on these would make it
    /// impossible to pause for breath while asking for something.
    @Test("Thinking noises are not halts", arguments: [
        "wait", "hold on", "one second", "um", "uh", "let me think", "hang on",
    ])
    func thinkingNoisesAreNotHalts(spoken: String) {
        #expect(VoiceCommand.read(spoken) == .instruction)
    }

    @Test("Nothing at all is not a halt")
    func silenceIsNotAHalt() {
        #expect(VoiceCommand.read("") == .instruction)
        #expect(VoiceCommand.read("   ") == .instruction)
    }
}
