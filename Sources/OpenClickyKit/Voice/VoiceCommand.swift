import Foundation

/// Reads an utterance that is about the session rather than a task for it.
///
/// One rule, and it exists because the obvious behaviour is actively wrong. Saying
/// "stop" to a running agent already cancels it — barge-in fires on the first syllable —
/// and then the words arrive, get submitted as an instruction, and the agent starts a
/// *new* run to work out what "stop" means. The user asked it to stop and it took that
/// as something to do. From the outside it is indistinguishable from being ignored,
/// which is how a session ends up being quit from the Dock.
///
/// Held to `VoiceApproval`'s standard rather than a looser one, for the same reason:
/// the phrase must be a halt and **nothing else**. "Stop" halts; "stop the music" is an
/// instruction about iTunes and must reach the agent intact. A transcript is a guess and
/// the microphone hears the whole room, so a rule that matched a halt *inside* a
/// sentence would silently swallow real work.
public enum VoiceCommand {

    /// What an utterance turned out to be.
    public enum Reading: Sendable, Equatable {
        /// Stop what you are doing, and say nothing more about it.
        case halt
        /// An ordinary instruction. The overwhelming majority.
        case instruction
    }

    /// Phrases that mean "stop", and mean only that.
    ///
    /// Two families, kept together because they resolve to the same thing here: the
    /// ones that abandon the task ("cancel that", "forget it") and the ones that only
    /// ask for quiet ("be quiet", "that's enough"). Separating them would need the
    /// session to know whether the voice it is being asked to stop belongs to a run
    /// that should survive, and it does not — `cancelRun` is the single cancellation
    /// path, and a second one that stopped the speaking without stopping the work would
    /// leave a run going with nothing left to report it.
    ///
    /// Deliberately without "wait", "hold on" and "one second": those are said *while
    /// thinking*, mid-instruction, and cancelling on them would make it impossible to
    /// pause for breath while asking for something.
    private static let halts: Set<String> = [
        "stop", "stop it", "stop that", "stop please", "please stop",
        "cancel", "cancel that", "cancel it",
        "never mind", "nevermind", "forget it", "forget that",
        "abort", "quit", "halt",
        "be quiet", "quiet", "shut up", "that's enough", "thats enough", "enough",
    ]

    public static func read(_ spoken: String) -> Reading {
        halts.contains(VoiceApproval.normalize(spoken)) ? .halt : .instruction
    }
}
