import Foundation

/// Who is holding the floor, and what happens when that changes.
///
/// A voice session is three parties contending for one channel: the person, the agent's
/// speech, and the agent's actions. Nearly all of the difficulty is in the transitions
/// — barge-in, echo, and the moment a run ends while someone is mid-sentence — and none
/// of it is difficulty that needs a microphone or a socket to reason about. So this is a
/// value type over an input alphabet, returning effects it does not perform.
///
/// That shape is the whole point. The audio stack cannot be driven by a test: it needs a
/// device, a TCC grant, a live websocket and a person willing to talk to it. Every rule
/// that matters here — that speaking while the agent works stops the agent, that the
/// agent's own voice is never mistaken for the user's, that a cancelled run leaves the
/// mic open rather than deaf — is decidable from the transition alone, and a rule that
/// can only be checked by talking to the machine is a rule that will be checked once.
///
/// It performs nothing and owns nothing. `AppDelegate` maps `Effect` onto the surfaces
/// that already exist, and the most important mapping is that `.cancelRun` becomes
/// `handleEscape()` — the single cancellation path, which cancels the run *and* answers
/// whatever approval or question the loop is suspended inside. Barge-in that built its
/// own way to stop a run would be a second path with the same obligation, and the first
/// one exists because forgetting that obligation hangs the loop.
public struct VoiceSession: Sendable, Equatable {

    /// Who holds the floor.
    public enum Phase: Sendable, Equatable {
        /// Not listening. The session is off.
        case idle
        /// Mic open, nobody talking.
        case listening
        /// The user is talking. Partial transcripts are arriving.
        case hearing
        /// The agent is running a task. The mic stays open — that is what makes
        /// barge-in possible — and anything heard now is an interruption.
        case working
        /// The agent is talking. The mic *also* stays open; see `Effect.gateMic`.
        case speaking
        /// The gate is holding a destructive call, and the question has been asked out
        /// loud. The run is suspended inside `PermissionGate`, waiting on an answer.
        case awaitingApproval
    }

    /// Something that happened, from the audio stack, the agent, or the user.
    public enum Input: Sendable, Equatable {
        /// The session was started or stopped by the user.
        case start
        case stop
        /// Voice activity detection fired. Not a transcript — this is the earliest
        /// possible signal, and barge-in has to act on the earliest one to feel
        /// immediate rather than polite.
        case speechDetected
        /// A transcript fragment. `isFinal` marks the end of an utterance.
        case transcript(String, isFinal: Bool)
        /// The agent began working on a task.
        case agentStartedWorking
        /// The agent has something to say. Phase 4 fills this; Phase 3 only has to
        /// hold the floor correctly when it happens.
        case agentWantsToSpeak(String)
        /// The synthesiser finished the last queued utterance.
        case speechFinished
        /// The run ended, by completion or by cancellation.
        case agentFinished
        /// The gate stopped on a destructive call and needs an answer.
        case agentAwaitingApproval(String)
    }

    /// Something for the caller to do. Order within a batch is significant.
    public enum Effect: Sendable, Equatable {
        case openMic
        case closeMic
        /// Whether the transcriber should discard what it hears.
        ///
        /// Not a mute. The mic is never actually shut while the agent speaks, because
        /// a session that goes deaf whenever it is talking cannot be interrupted, and
        /// being interruptible mid-sentence is most of what makes this feel live. It
        /// is the *transcript* that is suppressed, and only until echo cancellation is
        /// known to be running — see `hasEchoCancellation`.
        case gateMic(Bool)
        /// Stop the agent now. Maps to the existing single cancellation path.
        case cancelRun
        /// Drop everything queued or playing. Barge-in has to silence the current
        /// utterance, not merely stop queueing the next one.
        case clearAudioQueue
        case speak(String)
        /// A complete utterance from the user, to be run as a task.
        case submit(String)
        /// Answer the approval the gate is suspended inside.
        case answerApproval(Bool)
        /// The answer was not understood. Ask again rather than guessing, in either
        /// direction — a destructive call approved by a mishearing is the worst thing
        /// this application can do, and one denied by a mishearing without saying so
        /// leaves the user believing they were ignored.
        case repeatQuestion(String)
    }

    public private(set) var phase: Phase = .idle

    /// The utterance in progress, as the transcriber currently has it.
    ///
    /// Public so a surface can show what the session thinks it is hearing. Someone
    /// speaking to a program with no visible feedback cannot tell a mic that is not
    /// listening from one that is mishearing, and those need opposite responses —
    /// repeat yourself, or stop and fix the input. Cleared the moment an utterance is
    /// submitted or abandoned, so it never shows the last thing said as though it were
    /// the current one.
    public private(set) var heard = ""

    /// The question the gate is waiting on, kept so an unclear answer can be met with
    /// the question again rather than with a bare "sorry?" — which asks the user to
    /// remember what they were being asked about while an action hangs.
    private var pendingQuestion = ""

    /// Whether the input device is cancelling our own output out of what it hears.
    ///
    /// The agent speaks through the same machine it is listening on, so without this
    /// its own voice arrives at the microphone a few milliseconds later and reads as
    /// the user interrupting — the session barges in on itself, cancels its own run,
    /// and does it again on the next sentence. This is the audio-domain form of the
    /// invariant this project keeps rediscovering: *our own surface is not the user's*.
    /// An action verifying itself against our own terminal, a UI change we caused
    /// counting as one we observed, and the agent hearing itself speak are the same
    /// mistake in three places.
    ///
    /// When the platform confirms echo cancellation is on, the mic is trusted while
    /// speaking and barge-in works mid-sentence. When it cannot be turned on, the
    /// transcript is gated for the duration instead: the cost is that the user has to
    /// wait for a sentence to end before interrupting, which is a worse session but a
    /// working one. Defaulting to *false* is deliberate — an unconfirmed capability is
    /// treated as absent, because guessing wrong in the other direction produces a
    /// session that cancels its own runs and looks possessed.
    public let hasEchoCancellation: Bool

    public init(hasEchoCancellation: Bool = false) {
        self.hasEchoCancellation = hasEchoCancellation
    }

    /// Whether speech heard right now would interrupt something.
    ///
    /// `.awaitingApproval` is deliberately absent. The agent has just asked a question
    /// out loud and is suspended waiting for the answer, so the next thing it hears is
    /// the answer — treating it as barge-in would cancel the run every single time
    /// somebody replied to it, which is the one moment speech is most expected.
    public var isInterruptible: Bool { phase == .working || phase == .speaking }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch input {

        case .start:
            guard phase == .idle else { return [] }
            phase = .listening
            heard = ""
            return [.openMic, .gateMic(false)]

        case .stop:
            guard phase != .idle else { return [] }
            let wasBusy = isInterruptible
            phase = .idle
            heard = ""
            pendingQuestion = ""
            // Cancelling on the way out for the same reason `cancelPendingPrompts`
            // exists: a run left going after its only input surface has closed is a
            // run nobody can stop.
            return (wasBusy ? [.cancelRun] : []) + [.clearAudioQueue, .closeMic]

        case .speechDetected:
            switch phase {
            case .idle:
                return []
            case .listening, .hearing:
                phase = .hearing
                return []
            case .awaitingApproval:
                // Someone answering the question that was just asked. Stay put: the
                // transcript branch below reads the words, and cancelling here would
                // abort the run every time anybody replied.
                return []
            case .working, .speaking:
                // The whole feature, and it fires on detection rather than on a
                // transcript. Waiting for words would put a sentence's worth of
                // latency between "the user started talking over it" and "it stopped",
                // which is exactly the delay that makes an assistant feel like a
                // recording rather than a participant.
                phase = .hearing
                heard = ""
                return [.cancelRun, .clearAudioQueue, .gateMic(false)]
            }

        case let .transcript(text, isFinal):
            // Discarded outright while the agent talks and the device cannot cancel
            // its own output. This is the branch that stops the session hearing itself.
            guard phase != .idle, !(phase == .speaking && !hasEchoCancellation) else {
                return []
            }

            // An answer, not an instruction. Read before the interruption rules below,
            // because in this phase there is nothing to interrupt — the loop is parked
            // inside the gate — and submitting "yes" as a *task* would leave the run
            // suspended forever while starting a second one on top of it.
            if phase == .awaitingApproval {
                guard isFinal else {
                    heard = text
                    return []
                }
                heard = ""
                switch VoiceApproval.read(text) {
                case .approved:
                    phase = .working
                    pendingQuestion = ""
                    return [.answerApproval(true)]
                case .denied:
                    phase = .working
                    pendingQuestion = ""
                    return [.answerApproval(false)]
                case .unclear:
                    // Neither answered nor abandoned. A destructive call approved by a
                    // mishearing is the worst thing this application can do; one denied
                    // by a mishearing, silently, leaves the user believing they were
                    // ignored. So it is asked again and the gate keeps waiting.
                    return [.repeatQuestion(pendingQuestion)]
                }
            }
            // A transcript arriving in `.working` or `.speaking` means detection was
            // missed — some transcribers emit words before their VAD settles — so it
            // has to interrupt too, or barge-in would depend on which signal won a
            // race. Empty finals are silence, not an utterance, and must not cancel.
            var effects: [Effect] = []
            if isInterruptible {
                guard !text.trimmed.isEmpty else { return [] }
                phase = .hearing
                heard = ""
                effects = [.cancelRun, .clearAudioQueue, .gateMic(false)]
            } else {
                phase = .hearing
            }

            guard isFinal else {
                heard = text
                return effects
            }
            // The final carries the whole utterance, not the tail of it — that is the
            // contract of every streaming transcriber this is written against, and the
            // interim text is a running guess at the same span rather than a prefix to
            // be concatenated. Appending would double every sentence.
            let utterance = text.trimmed
            heard = ""
            phase = .listening
            // A final that says nothing is a cough, a door, or the end of a pause.
            guard !utterance.isEmpty else { return effects }
            return effects + [.submit(utterance)]

        case let .agentAwaitingApproval(question):
            guard phase != .idle else { return [] }
            phase = .awaitingApproval
            heard = ""
            pendingQuestion = question
            // Asking is entering the phase, so the question is spoken from here rather
            // than left to a separate `agentWantsToSpeak` the caller has to remember —
            // a gate that stops the run and says nothing is indistinguishable from one
            // that hung.
            //
            // The mic is ungated even though we are about to talk, and unlike every
            // other speech in this file that is not conditional on echo cancellation.
            // The answer is the next thing that will be said; a session that gates
            // itself while asking a question cannot hear the reply, and the run stays
            // parked in the gate forever. The cost without cancellation is that the
            // tail of our own question may be transcribed — which `VoiceApproval` reads
            // as unclear and asks again, rather than as consent.
            return [.gateMic(false), .speak(question)]

        case .agentStartedWorking:
            guard phase != .idle else { return [] }
            // Lifting the gate is not optional here, and it is the one transition out
            // of `.speaking` that used to forget to. The realistic sequence is Phase
            // 4's: the agent says "bringing VS Code to the front" and starts executing
            // before the sentence has finished playing — which left the transcript
            // gated for the whole of the work that followed, so the mic was deaf
            // during exactly the part a user most wants to interrupt. Nothing threw and
            // nothing logged; barge-in simply stopped answering. Found by
            // `gateNeverStrandsTheMicrophone`, not by reading the code.
            let wasSpeaking = phase == .speaking
            phase = .working
            heard = ""
            return wasSpeaking ? [.gateMic(false)] : []

        case let .agentWantsToSpeak(text):
            guard phase != .idle else { return [] }
            // Refused while the user is talking. Speaking over someone mid-sentence is
            // the thing barge-in exists to stop the agent doing, and an agent that does
            // it to the user while forbidding the reverse is worse than a silent one.
            guard phase != .hearing else { return [] }
            // Asking the question does not leave `.awaitingApproval`: the gate is still
            // holding the call, and the phase is what routes the reply to it instead of
            // submitting it as a new task.
            guard phase != .awaitingApproval else { return [.speak(text)] }
            phase = .speaking
            return [.gateMic(!hasEchoCancellation), .speak(text)]

        case .speechFinished:
            guard phase == .speaking else { return [] }
            phase = .listening
            return [.gateMic(false)]

        case .agentFinished:
            switch phase {
            case .idle:
                return []
            case .hearing:
                // The user is already partway into the next instruction. Their turn
                // outranks the tidying-up of the one that just ended.
                return []
            case .listening, .working, .speaking, .awaitingApproval:
                phase = .listening
                return [.gateMic(false)]
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
