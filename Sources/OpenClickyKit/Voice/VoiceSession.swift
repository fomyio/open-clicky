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
        /// A transcript fragment. `isFinal` marks a *segment* that will not be revised
        /// — not the end of the turn. See `utterance`.
        case transcript(String, isFinal: Bool)
        /// The endpointer decided the turn is over, with or without words.
        ///
        /// The counterpart to `speechDetected`, and both exits from `.hearing`: the
        /// noise that never became words, and the sentence that finished. Detection
        /// fires on a cough, a door, or a neighbour's voice as readily as on a
        /// sentence, and none of those ever produce a transcript — so without this the
        /// session parked in `.hearing` with nothing left that could move it, and
        /// `agentWantsToSpeak` refuses to speak over someone who is talking. The agent
        /// went silently mute for the rest of the session.
        ///
        /// It is now also what *submits*. A settled segment no longer starts a task on
        /// its own; this is the signal that the person stopped talking.
        case speechEnded
        /// The settle timer expired: nothing further has been heard for
        /// `VoiceSession.settle` seconds. The safety net under `speechEnded`, for the
        /// vendor that announces the end of a turn before it delivers the words in it.
        case endOfTurn
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
        /// Start (or restart) the settle timer, which feeds `.endOfTurn` back after the
        /// given delay. Re-arming replaces whatever was pending — this is a debounce on
        /// speech, not a queue of alarms.
        ///
        /// Two delays are used and the difference is the whole of `VoiceTurn`:
        /// `VoiceSession.settle` while someone may still be talking, and the longer
        /// `VoiceSession.grace` when they have stopped but the words say they had not
        /// finished.
        case armEndOfTurn(after: TimeInterval)
        /// Cancel a pending settle timer. Returned wherever the turn resolved on its
        /// own, so a late alarm cannot flush a turn that is already gone.
        case disarmEndOfTurn
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

    /// How long a turn must go quiet before it is taken as finished.
    ///
    /// The safety net under the vendor's own endpointer, not a replacement for it: a
    /// `speechEnded` that arrives with the words already in hand submits immediately,
    /// and this only decides the cases where one of the two is missing. Long enough to
    /// cover the gap between OpenAI announcing the end of a turn and delivering its
    /// transcript, short enough that a vendor which never announces one at all still
    /// feels like it is listening rather than ignoring you.
    public static let settle: TimeInterval = 1.2

    /// How long to wait on someone who stopped mid-sentence.
    ///
    /// The endpointer has already spoken and would have taken the floor; this is the
    /// extra room given to a turn whose last word says it was not finished. Long enough
    /// to cover the four-second pause in the session that motivated `VoiceTurn`, short
    /// enough that a turn misjudged as unfinished still goes out while the speaker is
    /// waiting for it rather than wondering whether they were heard.
    public static let grace: TimeInterval = 3

    /// The settled segments of the turn in progress, joined.
    ///
    /// This is the fix for the defect that made the whole feature look dead. Deepgram
    /// finalises a *segment* every time the endpointer sees a pause — so "can you check
    /// the system settings for updates" arrived as three settled fragments — and the
    /// session submitted each one as its own task. Each submission superseded and
    /// cancelled the one before it, and the user's continued speech barged in on what
    /// was left, so a whole sentence produced three cancelled runs and no answer. The
    /// transcript looked perfect on screen the entire time, which is why the report was
    /// "it hears me and does nothing".
    ///
    /// A settled segment is therefore kept, not spent. What spends it is `speechEnded`
    /// — the endpointer saying the *person* stopped, rather than saying this phrase
    /// will not be revised.
    private var utterance = ""

    /// Whether a run is going, independent of who holds the floor.
    ///
    /// The phase cannot answer this. It leaves `.working` the moment anything is heard
    /// or said, and the run carries on underneath — which is exactly the window where
    /// "should these words stop it" has to be answerable.
    private var isRunInFlight = false

    /// How many turns this session has submitted, so the opener for each is a different
    /// one. Counted rather than randomised: the same phrase twice running is the tell
    /// that turns an assistant back into a recording, and a test cannot read a coin.
    private var turnsTaken = 0

    /// Whether the end of this turn has already been announced.
    ///
    /// The two vendors order the last two events differently and neither ordering is
    /// wrong: Deepgram sends the final segment and then says the turn ended, OpenAI
    /// says the turn ended and then sends the transcript for it. Remembering which has
    /// arrived lets whichever comes second submit immediately, so neither vendor pays
    /// `settle` for being the other one.
    private var turnEnded = false

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

    /// Whether our own speaker is still playing.
    ///
    /// Kept apart from `phase` because it is a fact about the audio device, not about
    /// who holds the floor, and the two come apart on the most ordinary sequence there
    /// is. `AgentLoop` emits a turn's prose *before* it runs that turn's tools, and
    /// `Narration.budget` is 300 characters — around twenty seconds of speech — so the
    /// next turn's `.agentStartedWorking` routinely arrives while the previous sentence
    /// is still coming out of the speaker.
    ///
    /// Keyed to the phase, the gate was lifted at exactly that moment: the utterance
    /// kept playing, returned through the microphone, and a transcript in `.working` is
    /// `isInterruptible` — so the session cancelled its own run, and then did it again
    /// on the next turn. On any Mac where `setVoiceProcessingEnabled` is refused, which
    /// is the deliberate default because an unconfirmed capability is treated as
    /// absent, that was every run. Nothing threw and nothing logged; the agent simply
    /// stopped itself.
    private var isSpeakingAloud = false

    public init(hasEchoCancellation: Bool = false) {
        self.hasEchoCancellation = hasEchoCancellation
    }

    /// The gate, decided by the speaker rather than by the phase.
    ///
    /// Every gate decision in this file goes through here, so that there is one answer
    /// to "is our own voice in the room right now" rather than one per transition —
    /// which is how the transition that forgot got written in the first place.
    private var micGate: Effect { .gateMic(isSpeakingAloud && !hasEchoCancellation) }

    /// Whether speech heard right now would interrupt something.
    ///
    /// `.awaitingApproval` is deliberately absent. The agent has just asked a question
    /// out loud and is suspended waiting for the answer, so the next thing it hears is
    /// the answer — treating it as barge-in would cancel the run every single time
    /// somebody replied to it, which is the one moment speech is most expected.
    public var isInterruptible: Bool { phase == .working || phase == .speaking }

    /// Ends the turn in progress and submits it, if there was anything in it.
    ///
    /// One place, because every route out of `.hearing` has to leave the same state
    /// behind — an accumulator that survived a submission would prepend the last
    /// instruction to the next one, which is a worse failure than the one this file
    /// was rewritten to fix: the agent would act on a sentence nobody said.
    ///
    /// A submitted turn leaves in `.speaking` rather than `.listening`, because the
    /// last thing it does is answer. The phase is set to `.listening` first and then
    /// moved on, so a turn that submits nothing — silence, or a halt — still lands
    /// where it should.
    private mutating func flush() -> [Effect] {
        let complete = utterance.trimmed
        utterance = ""
        heard = ""
        turnEnded = false
        phase = .listening
        guard !complete.isEmpty else { return [] }
        // "Stop" is about the session, not a task for it. Submitted as an instruction
        // it starts a *new* run to work out what stopping means, on top of the one
        // barge-in has just cancelled — so the one phrase everybody reaches for when
        // they want it to stop was the one phrase that made it start again.
        //
        // Cancelled rather than merely dropped: barge-in fires on detection and would
        // normally have stopped the run before these words arrived, but only if the
        // VAD saw it. Saying it through a gated microphone, or in a phase that is not
        // interruptible, leaves nothing else that would.
        guard VoiceCommand.read(complete) == .instruction else {
            isRunInFlight = false
            return [.cancelRun, .clearAudioQueue]
        }
        // Answered before it is sent anywhere. A typed session shows "Thinking…" the
        // instant Return is pressed; a spoken one had nothing at all, and the silence
        // while a planner ran — twenty-five seconds of it, in the session this was
        // written from — does not read as "working" on a voice channel. It reads as
        // "it did not hear me", so the sentence gets said again, which barges in and
        // cancels the run that was about to answer it.
        //
        // Ahead of `.submit` in the batch, so the receipt is out of the speaker before
        // the first byte goes out; the synthesiser plays on its own thread, so this
        // costs the run nothing.
        let opener = VoiceFiller.opener(turn: turnsTaken)
        turnsTaken &+= 1
        phase = .speaking
        isSpeakingAloud = true
        return [micGate, .speak(opener), .submit(complete)]
    }

    /// Joins two spans of one sentence, tolerating either being empty.
    private func joined(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        return head + " " + tail
    }

    public mutating func handle(_ input: Input) -> [Effect] {
        switch input {

        case .start:
            guard phase == .idle else { return [] }
            phase = .listening
            heard = ""
            utterance = ""
            turnEnded = false
            isRunInFlight = false
            isSpeakingAloud = false
            return [.openMic, micGate]

        case .stop:
            guard phase != .idle else { return [] }
            let wasBusy = isInterruptible || isRunInFlight
            isRunInFlight = false
            phase = .idle
            heard = ""
            utterance = ""
            turnEnded = false
            pendingQuestion = ""
            // `.clearAudioQueue` below stops the synthesiser mid-word, so by the time
            // the caller has performed these the speaker is silent.
            isSpeakingAloud = false
            // Cancelling on the way out for the same reason `cancelPendingPrompts`
            // exists: a run left going after its only input surface has closed is a
            // run nobody can stop.
            return (wasBusy ? [.cancelRun] : []) + [.clearAudioQueue, .closeMic]

        case .speechDetected:
            switch phase {
            case .idle:
                return []
            case .listening, .hearing:
                // Not a reset of `utterance`: Deepgram re-announces detection between
                // the segments of one sentence, and clearing here would throw away
                // everything said before the speaker drew breath — which is the defect
                // `utterance` exists to fix, reintroduced one branch along. A turn is
                // ended by `speechEnded`, and only there.
                phase = .hearing
                turnEnded = false
                return [.armEndOfTurn(after: Self.settle)]
            case .awaitingApproval:
                // Someone answering the question that was just asked. Stay put: the
                // transcript branch below reads the words, and cancelling here would
                // abort the run every time anybody replied.
                return []
            case .working, .speaking:
                // **Detection stops the talking. Only words stop the work.**
                //
                // This used to cancel the run here, on the earliest signal there is,
                // and the argument for that was latency: waiting for words puts a
                // sentence between someone talking over the agent and the agent
                // stopping. The argument still holds and the code still honours it for
                // the half it is true of — the speaker is silenced on this very event,
                // which is the part a person actually perceives as being interrupted.
                //
                // What it cannot do any more is end the run. Voice activity fires on a
                // cough, a door, a chair, a neighbour: the detector says *something was
                // loud*, never *someone addressed me*. Cancelling on that was survivable
                // while the agent spoke once or twice a run. It is not survivable now
                // that it narrates every action — the microphone is open and unGated for
                // most of a run, and any noise in the room during a thirty-second task
                // ended it. A run killed by a cough is indistinguishable, from the
                // outside, from the agent ignoring the instruction.
                //
                // So the cancel moves one event later, to the first word actually
                // transcribed — which is fast, because interim results arrive while the
                // sentence is still being said, and is evidence that a person is
                // talking rather than that a room made a noise.
                phase = .hearing
                heard = ""
                // The interrupted run's turn is over; what is being said now is a new
                // one, and nothing settled before it belongs to it.
                utterance = ""
                turnEnded = false
                isSpeakingAloud = false
                return [.clearAudioQueue, micGate, .armEndOfTurn(after: Self.settle)]
            }

        case .speechEnded:
            guard phase == .hearing else { return [] }
            // The words are already in hand, so this is the turn. Submitted from here
            // rather than from the last settled segment, which is the whole repair:
            // a segment says "this phrase will not be revised", and only the endpointer
            // says "the person stopped talking".
            if !utterance.trimmed.isEmpty {
                // Unless the words say otherwise. An endpointer answers a question
                // about silence, and silence is not the question: "can you check for me
                // the" was followed by a four-second pause in the session this comes
                // from — past any threshold anybody would set — and answering it meant
                // answering half a sentence. `turnEnded` is deliberately *not* set
                // here, so the segment that arrives next extends the turn instead of
                // flushing it the moment it lands.
                guard !VoiceTurn.seemsUnfinished(utterance) else {
                    return [.armEndOfTurn(after: Self.grace)]
                }
                turnEnded = true
                return [.disarmEndOfTurn] + flush()
            }
            turnEnded = true
            // Announced before the words arrived — OpenAI's order. Whatever is still
            // outstanding is on its way, so the turn is left open and the transcript
            // that follows submits it. `armEndOfTurn` is what stops that being a
            // promise: if nothing follows, the settle timer closes the turn.
            guard heard.isEmpty else { return [.armEndOfTurn(after: Self.settle)] }
            // Nothing was said at all — a cough, a door, a neighbour. The exit
            // `.hearing` did not used to have.
            phase = .listening
            turnEnded = false
            return [.disarmEndOfTurn]

        case .endOfTurn:
            // Only the phase that can own a turn, so an alarm outliving its turn —
            // armed just before a barge-in, say — cannot submit into a run.
            guard phase == .hearing else { return [] }
            // Unconditional, `VoiceTurn` included: the grace it asks for has now been
            // given, and a rule that could withhold a turn twice is one that can
            // withhold it forever. Nothing may swallow what somebody said.
            return flush()

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
                // The gate is restated on the way out because the phase that ungated it
                // is over. Someone can answer while the tail of the question is still
                // playing — with no echo cancellation that tail then arrives as a
                // transcript in `.working`, where it is `isInterruptible`, and cancels
                // the run its own answer just released.
                case .approved:
                    phase = .working
                    pendingQuestion = ""
                    return [micGate, .answerApproval(true)]
                case .denied:
                    phase = .working
                    pendingQuestion = ""
                    return [micGate, .answerApproval(false)]
                case .unclear:
                    // Neither answered nor abandoned. A destructive call approved by a
                    // mishearing is the worst thing this application can do; one denied
                    // by a mishearing, silently, leaves the user believing they were
                    // ignored. So it is asked again and the gate keeps waiting.
                    //
                    // Counted as speaking aloud even though it is not a `.speak`: the
                    // caller says it through the same synthesiser, and a sentence the
                    // session does not know it is playing is one it will open the
                    // microphone onto the moment the phase changes.
                    isSpeakingAloud = true
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
                // Cleared for the same reason the detection branch clears it: this is
                // the start of a new turn, and nothing settled before the agent took
                // the floor belongs to it.
                utterance = ""
                turnEnded = false
                isSpeakingAloud = false
                effects = [.clearAudioQueue, micGate]
            } else {
                phase = .hearing
            }
            // **This is barge-in**, moved one event later than the noise that announced
            // it. Words are evidence that a person is talking; voice activity is only
            // evidence that the room made a sound, and cancelling on that ended runs on
            // coughs and doors — which looks exactly like being ignored.
            //
            // Interim transcripts count, and that is what keeps it feeling immediate:
            // they arrive while the sentence is still being said, so the run stops a
            // word or two in rather than a sentence later. Once per run, because a
            // sentence produces a dozen of them and a run can only be cancelled once —
            // and because `cancelRun` is `handleEscape`, which once the run is gone
            // dismisses the overlay instead of stopping it.
            if isRunInFlight, !text.trimmed.isEmpty {
                isRunInFlight = false
                effects.insert(.cancelRun, at: 0)
            }

            // An interim is a running guess at the *current segment*, not at the whole
            // turn — so it is shown after whatever has already settled rather than
            // instead of it, or the screen would lose the first half of a long sentence
            // the moment the speaker paused.
            guard isFinal else {
                heard = joined(utterance, text.trimmed)
                return effects + [.armEndOfTurn(after: Self.settle)]
            }
            // Settled, and therefore kept. Appending is right here for the same reason
            // replacing was right above: these are consecutive spans of one sentence,
            // and the vendor will not send them again.
            let segment = text.trimmed
            guard !segment.isEmpty else { return effects + [.armEndOfTurn(after: Self.settle)] }
            utterance = joined(utterance, segment)
            heard = utterance
            // The endpointer already said the turn was over and this is the transcript
            // it owed — OpenAI's order. Nothing more is coming, so waiting out `settle`
            // would only add silence between the user finishing and the agent starting.
            if turnEnded { return effects + [.disarmEndOfTurn] + flush() }
            return effects + [.armEndOfTurn(after: Self.settle)]

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
            // The mic is ungated even though we are about to talk, and this is the one
            // gate decision in the file that does not go through `micGate`: it ignores
            // both echo cancellation and whether a previous sentence is still playing.
            // The answer is the next thing that will be said; a session that gates
            // itself while asking a question cannot hear the reply, and the run stays
            // parked in the gate forever. The cost without cancellation is that the
            // tail of our own question may be transcribed — which `VoiceApproval` reads
            // as unclear and asks again, rather than as consent.
            // Conditional for the same reason as `agentWantsToSpeak` below: a blank
            // question is never queued, so it would never report finishing.
            isSpeakingAloud = !question.trimmed.isEmpty
            return [.gateMic(false), .speak(question)]

        case .agentStartedWorking:
            guard phase != .idle else { return [] }
            // The gate is restated here rather than lifted here, and the difference is
            // the whole of this transition's history. The realistic sequence is Phase
            // 4's: the agent says "bringing VS Code to the front" and starts executing
            // before the sentence has finished playing. Returning nothing left the
            // transcript gated for the whole of the work that followed, so the mic was
            // deaf during exactly the part a user most wants to interrupt. Returning
            // `.gateMic(false)` — the repair for that — opened the mic onto a speaker
            // that was still talking, so the sentence came back in and cancelled the
            // run it had just announced.
            //
            // Both readings were about the phase. The question is whether our own voice
            // is audible, which `micGate` answers and the phase cannot.
            //
            // The run is noted either way, because it is a fact about the agent and not
            // about the floor — it is what lets the next word the user says cancel this.
            isRunInFlight = true
            // Except from someone mid-sentence. This took the floor unconditionally and
            // cleared `heard` with it, so a turn beginning while the user was partway
            // through an instruction wiped what they had said so far and moved the
            // session to `.working` — where the rest of the sentence reads as an
            // interruption and throws away the settled half. The user watched the first
            // half of their own sentence disappear, and the agent acted on the rest of
            // it as though it were the whole.
            //
            // The same rule `.agentFinished` already keeps, and for the same reason:
            // *their turn outranks the bookkeeping of ours.* The floor comes back when
            // they finish, through `flush`.
            guard phase != .hearing else { return [micGate] }
            phase = .working
            heard = ""
            return [micGate]

        case let .agentWantsToSpeak(text):
            guard phase != .idle else { return [] }
            // Refused while the user is talking. Speaking over someone mid-sentence is
            // the thing barge-in exists to stop the agent doing, and an agent that does
            // it to the user while forbidding the reverse is worse than a silent one.
            guard phase != .hearing else { return [] }
            // Nothing to play, so nothing to wait for. `SystemSpeechSynthesizer.speak`
            // drops a blank utterance without queuing it, so no `didFinish` fires and
            // no `.speechFinished` ever arrives — and now that the gate follows the
            // speaker rather than the phase, `isSpeakingAloud` would stay true for the
            // rest of the session and hold the microphone gated on any device without
            // echo cancellation. A claim to be speaking has to be one the synthesiser
            // will honour.
            guard !text.trimmed.isEmpty else { return [] }
            // Asking the question does not leave `.awaitingApproval`: the gate is still
            // holding the call, and the phase is what routes the reply to it instead of
            // submitting it as a new task.
            guard phase != .awaitingApproval else {
                isSpeakingAloud = true
                return [.speak(text)]
            }
            phase = .speaking
            isSpeakingAloud = true
            return [micGate, .speak(text)]

        case .speechFinished:
            guard phase != .idle else { return [] }
            isSpeakingAloud = false
            // The lift is returned from *any* phase, and that is the half this used to
            // get wrong. Since `.agentStartedWorking` and `.agentFinished` now leave the
            // gate up while the speaker is still playing, the only thing that takes it
            // down again is this — and a `guard phase == .speaking` meant the utterance
            // that ended in `.working` or `.awaitingApproval` never lifted it, which is
            // a mic gated with nobody talking: the opposite failure, and a deaf session.
            //
            // Returning to `.listening` is still only `.speaking`'s to do. The floor
            // belongs to the run in the other two, and handing it back because a
            // sentence ended would abandon work that is still going.
            if phase == .speaking { phase = .listening }
            return [micGate]

        case .agentFinished:
            isRunInFlight = false
            switch phase {
            case .idle:
                return []
            case .hearing:
                // The user is already partway into the next instruction. Their turn
                // outranks the tidying-up of the one that just ended.
                return []
            case .listening, .working, .speaking, .awaitingApproval:
                phase = .listening
                // Not an unconditional lift: a run can end while its last narration is
                // still playing, and opening the mic onto our own voice is what
                // `isSpeakingAloud` exists to stop. `.speechFinished` lifts it.
                return [micGate]
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
