import Testing
import Foundation
@testable import OpenClickyKit

/// Barge-in is the feature people judge a voice assistant on, and it is the one part of
/// the audio stack that can be tested without a microphone. Everything here is a rule
/// about who holds the floor; none of it needs a device, a grant, a socket, or a person
/// willing to talk to it.
@Suite("Voice session")
struct VoiceSessionTests {

    /// A session already listening, which is where most rules start.
    private func listening(echoCancelled: Bool = true) -> VoiceSession {
        var session = VoiceSession(hasEchoCancellation: echoCancelled)
        _ = session.handle(.start)
        return session
    }

    private func working(echoCancelled: Bool = true) -> VoiceSession {
        var session = listening(echoCancelled: echoCancelled)
        _ = session.handle(.agentStartedWorking)
        return session
    }

    private func speaking(echoCancelled: Bool = true) -> VoiceSession {
        var session = working(echoCancelled: echoCancelled)
        _ = session.handle(.agentWantsToSpeak("bringing VS Code to the front"))
        return session
    }

    /// What a batch of effects submitted, if anything.
    ///
    /// Every submission now travels alongside an opener — the receipt a listener needs
    /// while a planner runs — so a test that pinned the exact array would be asserting
    /// the wording of a filler phrase in the middle of a rule about turn assembly.
    private func submitted(in effects: [VoiceSession.Effect]) -> String? {
        for effect in effects {
            if case let .submit(task) = effect { return task }
        }
        return nil
    }

    /// What a batch said out loud, if anything.
    private func spoken(in effects: [VoiceSession.Effect]) -> String? {
        for effect in effects {
            if case let .speak(text) = effect { return text }
        }
        return nil
    }

    // MARK: - Barge-in

    /// **Detection stops the talking. Only words stop the work.**
    ///
    /// Detection is still the earliest signal there is, and the half of barge-in a
    /// person actually perceives — being talked over and having it stop — happens on
    /// it. What moved is the cancel. Voice activity says *something was loud*, never
    /// *someone addressed me*, so a cough, a door or a chair ended the run; and now
    /// that the agent narrates every action, the microphone is open and unGated for
    /// most of a run, which turned a survivable annoyance into the common case. A run
    /// killed by a cough looks exactly like one that ignored the instruction.
    @Test("Noise during a run silences the speaker without ending the run")
    func detectionSilencesButDoesNotCancel() {
        var session = working()
        let effects = session.handle(.speechDetected)
        #expect(effects.contains(.clearAudioQueue), "it kept talking over the user")
        #expect(!effects.contains(.cancelRun), "a cough ended the run")
        #expect(session.phase == .hearing)
    }

    @Test("Noise over the agent's own speech silences it too")
    func detectionDuringSpeechSilences() {
        var session = speaking()
        let effects = session.handle(.speechDetected)
        #expect(effects.contains(.clearAudioQueue))
        #expect(!effects.contains(.cancelRun))
        #expect(session.phase == .hearing)
    }

    /// The cancel is one event later than the noise, not a sentence later: interim
    /// transcripts arrive while the sentence is still being said, so the run stops a
    /// word or two in. That is the latency the old detection-based cancel was buying,
    /// bought again without paying for it with every cough in the room.
    @Test("The first word of a real interruption ends the run")
    func wordsEndTheRun() {
        var session = working()
        _ = session.handle(.speechDetected)
        #expect(session.handle(.transcript("no", isFinal: false)).contains(.cancelRun))
    }

    /// A run can only be cancelled once, and `cancelRun` is `handleEscape` — which,
    /// once the run is gone, dismisses the overlay instead of stopping anything. A
    /// sentence produces a dozen interim transcripts.
    @Test("A sentence cancels the run once, not once per interim")
    func theRunIsCancelledOnce() {
        var session = working()
        _ = session.handle(.speechDetected)
        #expect(session.handle(.transcript("no", isFinal: false)).contains(.cancelRun))
        #expect(!session.handle(.transcript("no open", isFinal: false)).contains(.cancelRun))
        #expect(!session.handle(.transcript("no open Safari", isFinal: true)).contains(.cancelRun))
    }

    /// Noise that never became words leaves the run exactly where it was. This is the
    /// case the whole change exists for.
    @Test("A cough during a run costs the run nothing")
    func aCoughDoesNotEndTheRun() {
        var session = working()
        #expect(!session.handle(.speechDetected).contains(.cancelRun))
        #expect(!session.handle(.speechEnded).contains(.cancelRun))
        #expect(!session.handle(.endOfTurn).contains(.cancelRun))
        // And the agent can carry on talking about the work it is still doing.
        #expect(session.handle(.agentWantsToSpeak("Still on it.")).contains(.speak("Still on it.")))
    }

    /// Some transcribers emit words before their VAD settles. If only detection could
    /// interrupt, barge-in would depend on which signal won a race.
    @Test("A transcript arriving without detection still interrupts")
    func transcriptAloneInterrupts() {
        var session = working()
        let effects = session.handle(.transcript("stop", isFinal: false))
        #expect(effects.contains(.cancelRun))
        #expect(session.phase == .hearing)
    }

    /// An empty final is silence — a pause ending, a door, a cough. Cancelling a run on
    /// one would make the agent uninterruptibly interrupted in a quiet room.
    @Test("Silence never cancels a run", arguments: ["", "   ", "\n", "\t "])
    func emptyTranscriptDoesNotCancel(text: String) {
        var session = working()
        #expect(session.handle(.transcript(text, isFinal: true)).isEmpty)
        #expect(session.phase == .working, "silence took the floor from the agent")
    }

    @Test("Nothing is interruptible when the session is off")
    func idleSessionIgnoresEverything() {
        var session = VoiceSession(hasEchoCancellation: true)
        #expect(session.handle(.speechDetected).isEmpty)
        #expect(session.handle(.transcript("hello", isFinal: true)).isEmpty)
        #expect(session.handle(.agentWantsToSpeak("hi")).isEmpty)
        #expect(session.handle(.agentStartedWorking).isEmpty)
        #expect(session.phase == .idle)
    }

    // MARK: - Hearing itself

    /// The audio-domain form of "our own surface is not the user's". Without this the
    /// agent's own voice returns through the mic, reads as an interruption, and the
    /// session cancels its own run — then does it again on the next sentence.
    @Test("Without echo cancellation the agent never hears itself speak")
    func speechIsNotMistakenForTheUser() {
        var session = speaking(echoCancelled: false)
        let effects = session.handle(.transcript("bringing VS Code to the front", isFinal: true))
        #expect(effects.isEmpty, "the agent transcribed its own voice")
        #expect(session.phase == .speaking)
    }

    /// Gating is the fallback, not the design. When the device cancels our output the
    /// mic is trusted while speaking, which is what makes mid-sentence interruption
    /// work at all.
    @Test("With echo cancellation the mic stays live while the agent speaks")
    func echoCancellationKeepsTheMicLive() {
        var session = speaking(echoCancelled: true)
        #expect(session.handle(.transcript("no, the other one", isFinal: false)).contains(.cancelRun))
    }

    @Test("The transcript gate follows the device's capability")
    func gateFollowsCapability() {
        var withAEC = working(echoCancelled: true)
        #expect(withAEC.handle(.agentWantsToSpeak("hello")).contains(.gateMic(false)))

        var without = working(echoCancelled: false)
        #expect(without.handle(.agentWantsToSpeak("hello")).contains(.gateMic(true)))
    }

    /// An unconfirmed capability is treated as absent. Guessing the other way produces
    /// a session that cancels its own runs and looks possessed.
    @Test("Echo cancellation is assumed absent unless confirmed")
    func echoCancellationDefaultsOff() {
        #expect(!VoiceSession().hasEchoCancellation)
    }

    /// Phase 4's normal flow — say what you are about to do, then do it — and the
    /// transition both previous readings of it got wrong, in opposite directions.
    ///
    /// Returning nothing left the transcript gated for the whole of the work, so the mic
    /// was deaf during exactly the part a user most wants to interrupt. Lifting it
    /// unconditionally, which was the repair for that, opened the mic onto a sentence
    /// that was still playing. Whether the gate comes down is a question about the
    /// speaker, so it follows the device's capability and nothing else.
    @Test("Starting work mid-sentence follows the speaker, not the phase")
    func workingAfterSpeakingLiftsTheGate() {
        var cancelling = speaking(echoCancelled: true)
        #expect(cancelling.handle(.agentStartedWorking).contains(.gateMic(false)))
        #expect(cancelling.phase == .working)
        // And the microphone is live, which is the point of lifting it: the words that
        // arrive through it are what cancel.
        _ = cancelling.handle(.speechDetected)
        #expect(cancelling.handle(.transcript("no", isFinal: false)).contains(.cancelRun))

        // Without cancellation the utterance is still audible in `.working`, and the
        // microphone hears it. Opening the gate here is the session barging in on
        // itself: our own narration returns, `.working` is interruptible, and the run
        // the sentence just announced is cancelled by the sentence announcing it.
        var gated = speaking(echoCancelled: false)
        #expect(gated.handle(.agentStartedWorking) == [.gateMic(true)])
        #expect(gated.phase == .working)
    }

    /// The whole reachable sequence, because each step of it is routine and only the
    /// sequence is wrong: narrate, act, and the next turn begins while `Narration.budget`
    /// — 300 characters, around twenty seconds — is still being read out. On a device
    /// where `setVoiceProcessingEnabled` is refused, which is the default this type
    /// assumes, the agent cancelled its own run here and did it again every turn.
    @Test("An agent narrating through its own next turn does not cancel itself")
    func narrationDoesNotBargeInOnItself() {
        var session = listening(echoCancelled: false)
        _ = session.handle(.transcript("change my VS Code theme", isFinal: true))
        // The turn has to actually end before the agent may take the floor — a settled
        // segment is not a turn, and the endpointer is what spends it.
        _ = session.handle(.speechEnded)
        _ = session.handle(.speechFinished)
        _ = session.handle(.agentStartedWorking)
        _ = session.handle(.agentWantsToSpeak("Sure — opening the command palette now."))

        // The tool runs, and the next turn starts on a speaker that is still playing.
        #expect(session.handle(.agentStartedWorking) == [.gateMic(true)],
                "the mic was opened onto our own voice")
        #expect(session.phase == .working)

        // What the gate is holding back: `.working` is interruptible, so the narration
        // arriving back through the microphone cancels the run that narration announced.
        var ungated = session
        #expect(ungated.handle(.transcript("opening the command palette now", isFinal: true))
                .contains(.cancelRun),
                "nothing was being protected — the transcript would not have cancelled")

        // And the session comes back to life on its own terms when the sentence ends.
        #expect(session.handle(.speechFinished) == [.gateMic(false)])
        _ = session.handle(.speechDetected)
        #expect(session.handle(.transcript("no", isFinal: false)).contains(.cancelRun))
    }

    /// The other half of tracking the speaker rather than the phase: once the gate can
    /// survive a phase change, the end of the utterance is the only thing that takes it
    /// down — from wherever the session has got to by then. A `guard phase == .speaking`
    /// here is a microphone gated with nobody talking, which is a deaf session.
    /// Now that the gate outlives the phase, the only thing that takes it down is the
    /// synthesiser reporting its queue empty — and a blank utterance is never queued, so
    /// it never reports anything. Believing we are speaking when nothing was ever handed
    /// to the speaker gates the microphone for the rest of the session.
    @Test("A blank utterance is not a claim to be speaking", arguments: ["", "  ", "\n"])
    func blankSpeechDoesNotStrandTheGate(blank: String) {
        var session = listening(echoCancelled: false)
        #expect(session.handle(.agentWantsToSpeak(blank)).isEmpty)
        #expect(session.phase == .listening)
        // The proof it is not stranded: the next transition does not gate.
        #expect(session.handle(.agentStartedWorking) == [.gateMic(false)])
    }

    @Test("The gate is lifted again when the agent stops talking, from any phase")
    func gateLiftsAfterSpeaking() {
        var session = speaking(echoCancelled: false)
        #expect(session.handle(.speechFinished) == [.gateMic(false)])
        #expect(session.phase == .listening)

        var working = speaking(echoCancelled: false)
        _ = working.handle(.agentStartedWorking)
        #expect(working.handle(.speechFinished) == [.gateMic(false)])
        // The run is still going; a sentence ending is not a reason to hand the floor
        // back and abandon it.
        #expect(working.phase == .working, "the end of a sentence ended the run's turn")

        var asking = speaking(echoCancelled: false)
        _ = asking.handle(.agentAwaitingApproval("Quit Safari?"))
        #expect(asking.handle(.speechFinished) == [.gateMic(false)])
        #expect(asking.phase == .awaitingApproval)
    }

    /// A run can end while its last narration is still playing. Handing the floor back
    /// is right; opening the microphone onto the sentence still coming out of the
    /// speaker is the same self-interruption in a different transition.
    @Test("A run ending mid-sentence returns the floor without opening the mic")
    func finishingDoesNotOpenTheMicOnOurOwnVoice() {
        var session = speaking(echoCancelled: false)
        #expect(session.handle(.agentFinished) == [.gateMic(true)])
        #expect(session.phase == .listening)
        #expect(session.handle(.speechFinished) == [.gateMic(false)])
    }

    // MARK: - Taking turns

    /// An agent that talks over the user while forbidding the reverse is worse than a
    /// silent one.
    @Test("The agent does not speak over someone mid-sentence")
    func agentWaitsWhileTheUserTalks() {
        var session = listening()
        _ = session.handle(.speechDetected)
        #expect(session.handle(.agentWantsToSpeak("as I was saying")).isEmpty)
        #expect(session.phase == .hearing)
    }

    /// `.hearing` used to be a trap. Detection is not a promise of an utterance — a
    /// cough, a door, or someone talking in the next room fires the VAD and produces no
    /// transcript ever — and the only ways out were a non-empty final, the agent
    /// starting work, or stopping the session. So the session sat in `.hearing`
    /// indefinitely, and because `agentWantsToSpeak` refuses to talk over someone who is
    /// mid-sentence, the agent went silently mute for the rest of the session. Nothing
    /// threw; it simply stopped having a voice.
    @Test("A noise that never became words gives the floor back")
    func noiseDoesNotParkTheSession() {
        var session = listening()
        _ = session.handle(.speechDetected)
        #expect(session.phase == .hearing)

        #expect(session.handle(.speechEnded) == [.disarmEndOfTurn])
        #expect(session.phase == .listening, "a cough took the floor for the session")
        // The mute this was found through: the agent can speak again.
        #expect(session.handle(.agentWantsToSpeak("Done.")).contains(.speak("Done.")))
    }

    /// The endpointer's "that turn is over" can arrive before the transcript for it —
    /// which is OpenAI's order, where `speech_stopped` precedes the completion it owes.
    /// Acting on it while words are still in flight would drop the sentence between the
    /// two, so the turn is left open and the transcript that follows closes it.
    @Test("A turn announced before its words waits for them, then submits at once")
    func speechEndedDoesNotPreemptAnUtterance() {
        var session = listening()
        _ = session.handle(.transcript("open my cal", isFinal: false))
        // Armed rather than acted on: if the words never arrive, the timer is what
        // stops the turn hanging open — a promise to wait is not a promise to finish.
        #expect(session.handle(.speechEnded) == [.armEndOfTurn])
        #expect(session.phase == .hearing, "the utterance in progress was abandoned")
        #expect(session.heard == "open my cal")
        // Submitted on arrival, not after another `settle`. The endpointer has already
        // spoken, so waiting again would put a second of silence between the user
        // finishing and the agent starting.
        let closing = session.handle(.transcript("open my calendar", isFinal: true))
        #expect(closing.contains(.disarmEndOfTurn))
        #expect(submitted(in: closing) == "open my calendar")
    }

    /// The defect this whole turn-assembly exists for, from a real session log.
    ///
    /// "Can you check the system settings if there are any updates?" was endpointed
    /// three times on the way through — a breath after "Hello?", another after "check
    /// for me the" — and each settled fragment was submitted as its own task. Every
    /// submission superseded and cancelled the one before it, and the user's continued
    /// speech barged in on whatever survived, so one sentence produced three cancelled
    /// runs and no answer at all. The transcript on screen looked perfect throughout,
    /// which is why the report was "it hears me and does nothing".
    @Test("A sentence with pauses in it is one task, not one per pause")
    func settledSegmentsAreJoinedIntoOneTurn() {
        var session = listening()
        _ = session.handle(.speechDetected)
        #expect(session.handle(.transcript("can you check", isFinal: true)) == [.armEndOfTurn],
                "a settled segment started a task on its own")
        _ = session.handle(.transcript("the system settings", isFinal: true))
        _ = session.handle(.transcript("for updates", isFinal: true))
        #expect(session.heard == "can you check the system settings for updates",
                "the screen lost the first half of the sentence at the first pause")

        let closing = session.handle(.speechEnded)
        #expect(closing.contains(.disarmEndOfTurn))
        #expect(submitted(in: closing) == "can you check the system settings for updates")
    }

    /// The vendor may not announce the end of a turn at all, or may lose the frame that
    /// would have. Without this the turn stays open forever: the words are held, the
    /// phase is `.hearing`, and `agentWantsToSpeak` refuses to talk over someone it
    /// believes is mid-sentence — the same mute that `speechEnded` was added to fix.
    @Test("A turn nobody closed is closed by the settle timer")
    func settleTimerClosesAnAbandonedTurn() {
        var session = listening()
        _ = session.handle(.transcript("open my calendar", isFinal: true))
        #expect(submitted(in: session.handle(.endOfTurn)) == "open my calendar")
    }

    /// An alarm armed for a turn that has since been interrupted must not put that
    /// turn's words into the run that replaced it.
    @Test("A settle timer that outlives its turn submits nothing")
    func staleSettleTimerIsInert() {
        var session = working()
        #expect(session.handle(.endOfTurn).isEmpty)
        #expect(session.phase == .working)

        var idle = VoiceSession()
        #expect(idle.handle(.endOfTurn).isEmpty)
    }

    /// Nothing may survive a submission. An accumulator carried into the next turn
    /// would prepend the last instruction to the next one — the agent acting on a
    /// sentence nobody said, which is worse than the defect that motivated joining.
    @Test("The turn is emptied by submitting it")
    func submittingClearsTheTurn() {
        var session = listening()
        _ = session.handle(.transcript("open my calendar", isFinal: true))
        _ = session.handle(.speechEnded)

        _ = session.handle(.transcript("close it", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "close it")
    }

    /// It is a signal about the microphone, not about the run. Arriving while the agent
    /// is working or talking it must change nothing at all — least of all cancel.
    @Test("The end of a noise is not an event in any other phase", arguments: [true, false])
    func speechEndedIsInertElsewhere(echo: Bool) {
        var idle = VoiceSession(hasEchoCancellation: echo)
        #expect(idle.handle(.speechEnded).isEmpty)
        #expect(idle.phase == .idle)

        var listening = self.listening(echoCancelled: echo)
        #expect(listening.handle(.speechEnded).isEmpty)
        #expect(listening.phase == .listening)


        var busy = working(echoCancelled: echo)
        #expect(busy.handle(.speechEnded).isEmpty)
        #expect(busy.phase == .working)

        var talking = speaking(echoCancelled: echo)
        #expect(talking.handle(.speechEnded).isEmpty)
        #expect(talking.phase == .speaking)
    }

    @Test("A finished utterance is submitted as a task, trimmed")
    func finalTranscriptBecomesATask() {
        var session = listening()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("open my", isFinal: false))
        _ = session.handle(.transcript("  open my calendar  ", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "open my calendar")
    }

    /// The interim text is a running guess at the *current segment*, not at the whole
    /// turn, so it replaces the last guess and is shown after whatever has settled.
    /// Appending interims to one another would double every sentence.
    @Test("Interim text is replaced by the next interim, never appended to it")
    func interimIsNotConcatenated() {
        var session = listening()
        _ = session.handle(.transcript("open", isFinal: false))
        _ = session.handle(.transcript("open my cal", isFinal: false))
        _ = session.handle(.transcript("open my calendar", isFinal: true))
        #expect(session.heard == "open my calendar")
        #expect(submitted(in: session.handle(.speechEnded)) == "open my calendar")
    }

    /// The running guess belongs *after* what has already settled. Showing it instead
    /// would wipe the first half of a long sentence off the screen the moment the
    /// speaker drew breath — the user watching their own words disappear.
    @Test("What has settled stays on screen while the next words arrive")
    func interimFollowsTheSettledText() {
        var session = listening()
        _ = session.handle(.transcript("can you check", isFinal: true))
        _ = session.handle(.transcript("the system", isFinal: false))
        #expect(session.heard == "can you check the system")
    }

    @Test("What is being heard is visible, and cleared once it is used")
    func interimTextIsExposedAndCleared() {
        var session = listening()
        _ = session.handle(.transcript("open my cal", isFinal: false))
        #expect(session.heard == "open my cal")
        _ = session.handle(.transcript("open my calendar", isFinal: true))
        _ = session.handle(.speechEnded)
        #expect(session.heard.isEmpty, "the last utterance lingered as though current")
    }

    /// Barge-in and the next instruction are one gesture: you interrupt *by* saying the
    /// thing you want instead.
    @Test("An interruption's own words become the next task")
    func interruptionCarriesTheNextInstruction() {
        var session = working()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("no, open Safari instead", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "no, open Safari instead")
    }

    /// Barge-in ends the interrupted turn as well as the run. Whatever had settled
    /// before the agent took the floor belonged to the instruction it was already
    /// carrying out, and prepending it to the correction would submit a sentence that
    /// is half the old task and half the new one.
    @Test("An interruption does not carry the previous turn's words into the next task")
    func interruptionStartsACleanTurn() {
        var session = listening()
        _ = session.handle(.transcript("open my calendar", isFinal: true))
        _ = session.handle(.speechEnded)
        _ = session.handle(.agentStartedWorking)

        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("no, Safari", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "no, Safari")
    }

    /// Barge-in cancels on the first syllable, then the words arrive — and submitting
    /// them started a *new* run to work out what "stop" meant, on top of the one that
    /// had just been cancelled. The user asked it to stop and it took that as something
    /// to do, which from the outside is indistinguishable from being ignored.
    @Test("Saying stop stops it, rather than becoming the next task")
    func aHaltIsNotAnInstruction() {
        var session = working()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("stop", isFinal: true))
        let effects = session.handle(.speechEnded)

        #expect(!effects.contains(where: {
            if case .submit = $0 { return true } else { return false }
        }), "the halt was handed to the agent as an instruction")
        #expect(effects.contains(.cancelRun))
        #expect(effects.contains(.clearAudioQueue))
        #expect(session.phase == .listening)
    }

    /// The narrowness is what makes the rule safe: a halt inside a sentence is an
    /// instruction about something, and swallowing it would break one whole class of
    /// request in a way only its absence would ever reveal.
    @Test("A halt with anything else attached is still a task")
    func aHaltInsideASentenceStillSubmits() {
        var session = listening()
        _ = session.handle(.transcript("stop the music", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "stop the music")
    }

    // MARK: - The gap before the agent speaks

    /// A typed session shows "Thinking…" the instant Return is pressed. A spoken one
    /// had nothing, and the planner in the session this was written from took
    /// twenty-five seconds. Silence on a voice channel does not read as "working" — it
    /// reads as "it did not hear me", so the sentence gets said again, which barges in
    /// and cancels the run that was about to answer it.
    @Test("A submitted turn is answered out loud before anything is sent")
    func submissionIsAcknowledgedAloud() {
        var session = listening()
        _ = session.handle(.transcript("check for updates", isFinal: true))
        let effects = session.handle(.speechEnded)

        let opener = spoken(in: effects)
        #expect(opener != nil, "the user got silence while a planner ran")
        #expect(!(opener ?? "").isEmpty)
        // Before the task goes anywhere, so the receipt is out of the speaker while the
        // first request is still in flight.
        let saidAt = effects.firstIndex { if case .speak = $0 { return true }; return false }
        let sentAt = effects.firstIndex { if case .submit = $0 { return true }; return false }
        #expect(saidAt != nil && sentAt != nil && saidAt! < sentAt!)
    }

    /// The gate has to follow the opener like any other utterance. It does not go
    /// through `agentWantsToSpeak`, so a batch that spoke without claiming the floor
    /// would open the microphone onto our own voice — the session barging in on its own
    /// acknowledgement, on every single turn.
    @Test("The opener claims the floor like any other thing the agent says")
    func openerHoldsTheFloor() {
        var session = listening(echoCancelled: false)
        _ = session.handle(.transcript("check for updates", isFinal: true))
        let effects = session.handle(.speechEnded)

        #expect(session.phase == .speaking)
        #expect(effects.contains(.gateMic(true)), "the mic was left open onto our own voice")
        // And it comes back down when the utterance ends, rather than staying gated.
        #expect(session.handle(.speechFinished).contains(.gateMic(false)))
    }

    /// The same phrase twice running is the tell that turns an assistant back into a
    /// recording.
    @Test("Consecutive turns are not acknowledged with the same words")
    func openersVary() {
        var session = listening()
        var said: [String] = []
        for phrase in ["check for updates", "open Safari", "close it"] {
            _ = session.handle(.transcript(phrase, isFinal: true))
            if let opener = spoken(in: session.handle(.speechEnded)) { said.append(opener) }
            _ = session.handle(.speechFinished)
            _ = session.handle(.agentFinished)
        }
        #expect(said.count == 3)
        #expect(Set(said).count == 3)
    }

    /// A halt is answered by stopping, not by a cheerful "one moment" over the top of
    /// the thing the user just asked it to stop doing.
    @Test("A halt is not acknowledged out loud")
    func haltsAreNotAcknowledged() {
        var session = working()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("stop", isFinal: true))
        #expect(spoken(in: session.handle(.speechEnded)) == nil)
    }

    /// The floor belongs to whoever is using it. A turn beginning while the user is
    /// partway through an instruction used to take it unconditionally and clear `heard`
    /// with it: the first half of their sentence vanished off the screen, the session
    /// moved to `.working` where the rest reads as an interruption, and the agent acted
    /// on the tail of a sentence as though it were the whole of one.
    @Test("A turn starting mid-sentence does not take the floor off the speaker")
    func startingWorkDoesNotInterruptTheSpeaker() {
        var session = listening()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("open my", isFinal: true))

        _ = session.handle(.agentStartedWorking)
        #expect(session.phase == .hearing, "the agent took the floor mid-sentence")
        #expect(session.heard == "open my", "half the sentence was wiped off the screen")

        // And the whole sentence survives to be submitted, not just its tail.
        _ = session.handle(.transcript("calendar", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "open my calendar")
    }

    /// The run is still noted, because that is a fact about the agent rather than about
    /// the floor — and it is what lets the next word cancel it.
    @Test("A turn starting mid-sentence is still cancellable by what follows")
    func startingWorkMidSentenceStaysCancellable() {
        var session = listening()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("no", isFinal: false))
        _ = session.handle(.agentStartedWorking)
        #expect(session.handle(.transcript("no wait", isFinal: false)).contains(.cancelRun))
    }

    @Test("A run ending returns the floor to the user")
    func finishingReturnsToListening() {
        var session = working()
        #expect(session.handle(.agentFinished).contains(.gateMic(false)))
        #expect(session.phase == .listening)
    }

    /// The user is already partway into the next instruction; the tidying-up of the one
    /// that just ended must not take the floor back off them.
    @Test("A run ending mid-sentence does not interrupt the user")
    func finishingDoesNotStealTheFloor() {
        var session = working()
        _ = session.handle(.speechDetected)
        #expect(session.handle(.agentFinished).isEmpty)
        #expect(session.phase == .hearing)
    }

    // MARK: - Narration

    /// The epic's flow — speak, act, speak, act — needs no new machinery: `AgentLoop`
    /// emits `.assistantText` *before* it runs that turn's tool calls, so one turn is
    /// one narration followed by its actions. This is that sequence, twice.
    @Test("Narrating, acting, narrating and acting again keeps the floor straight")
    func narrationAlternatesWithAction() {
        var session = listening()
        _ = session.handle(.transcript("change my VS Code theme", isFinal: true))
        _ = session.handle(.speechEnded)
        _ = session.handle(.speechFinished)

        _ = session.handle(.agentStartedWorking)
        #expect(session.handle(.agentWantsToSpeak("Sure, let me bring VS Code to the front."))
                .contains(.speak("Sure, let me bring VS Code to the front.")))
        #expect(session.phase == .speaking)

        // The action starts before the sentence has finished playing, which is the
        // sequence that used to strand the microphone gate.
        #expect(session.handle(.agentStartedWorking).contains(.gateMic(false)))
        #expect(session.handle(.agentWantsToSpeak("Opening the command palette now."))
                .contains(.speak("Opening the command palette now.")))
        _ = session.handle(.agentStartedWorking)
        #expect(session.handle(.agentFinished).contains(.gateMic(false)))
        #expect(session.phase == .listening)
    }

    /// The user must be able to stop a narration they have heard enough of. The audio
    /// stops on the noise — that is the part they feel — and the run stops on the words,
    /// which is what tells a real interruption from a passing one.
    @Test("Talking over a narration silences it, and the words then stop the run")
    func narrationIsInterruptible() {
        var session = working()
        _ = session.handle(.agentWantsToSpeak("Here is a long explanation nobody asked for"))
        let silenced = session.handle(.speechDetected)
        #expect(silenced.contains(.clearAudioQueue))
        #expect(!silenced.contains(.cancelRun))
        #expect(session.handle(.transcript("that's enough", isFinal: false)).contains(.cancelRun))
    }

    /// A second sentence in the same turn queues behind the first rather than
    /// re-entering the phase and re-gating the microphone.
    @Test("Consecutive narrations queue without churning the gate")
    func consecutiveNarrationsQueue() {
        var session = speaking(echoCancelled: false)
        let effects = session.handle(.agentWantsToSpeak("And then this."))
        #expect(effects.contains(.speak("And then this.")))
        #expect(session.phase == .speaking)
    }

    // MARK: - Answering the gate out loud

    private func awaitingApproval() -> VoiceSession {
        var session = working()
        _ = session.handle(.agentAwaitingApproval("Quit Safari? This closes 12 tabs."))
        return session
    }

    /// A gate that stops the run and says nothing is indistinguishable from one that
    /// hung, so asking is part of entering the phase rather than a second call the
    /// caller has to remember.
    @Test("Reaching the gate asks the question out loud, with the mic live")
    func approvalAsksAndListens() {
        var session = working()
        let effects = session.handle(.agentAwaitingApproval("Quit Safari?"))
        #expect(effects == [.gateMic(false), .speak("Quit Safari?")])
        #expect(session.phase == .awaitingApproval)
    }

    /// The subtle one. The agent has just asked a question and is suspended waiting for
    /// the reply, so the next thing it hears is the reply — treating it as barge-in
    /// would cancel the run every single time somebody answered.
    @Test("Answering the gate is not barge-in")
    func answeringDoesNotCancelTheRun() {
        var session = awaitingApproval()
        #expect(session.handle(.speechDetected).isEmpty)
        #expect(session.phase == .awaitingApproval)
        #expect(!session.isInterruptible)
    }

    /// Submitting "yes" as a *task* would leave the run suspended in the gate forever
    /// while starting a second one on top of it.
    @Test("A spoken answer resolves the gate rather than becoming a new task")
    func answerGoesToTheGateNotTheLoop() {
        var session = awaitingApproval()
        #expect(session.handle(.transcript("yes", isFinal: true))
                == [.gateMic(false), .answerApproval(true)])
        #expect(session.phase == .working)

        var refusing = awaitingApproval()
        #expect(refusing.handle(.transcript("no", isFinal: true))
                == [.gateMic(false), .answerApproval(false)])
    }

    /// Asking the question is the one place the gate is opened deliberately while the
    /// agent is talking — the answer is the next thing that will be said, and a session
    /// that cannot hear it parks the run in the gate forever. That exception belongs to
    /// `.awaitingApproval` and must not be carried out of it: someone can answer over
    /// the tail of the question, and on a device with no echo cancellation that tail
    /// then arrives as a transcript in `.working`, where it cancels the run its own
    /// answer just released.
    @Test("The approval exception ends with the approval")
    func answeringRestoresTheGate() {
        var session = working(echoCancelled: false)
        #expect(session.handle(.agentAwaitingApproval("Quit Safari?"))
                == [.gateMic(false), .speak("Quit Safari?")],
                "the mic must be live to hear the answer, cancellation or not")
        #expect(session.handle(.transcript("yes", isFinal: true))
                == [.gateMic(true), .answerApproval(true)])
        #expect(session.handle(.speechFinished) == [.gateMic(false)])
    }

    /// Neither answered nor abandoned. Approving on a mishearing is the worst thing this
    /// application can do; denying on one silently leaves the user believing they were
    /// ignored while an action hangs.
    @Test("An answer that was not understood asks again and keeps waiting", arguments: [
        "sure", "yes and open Safari", "mm", "what", "",
    ])
    func unclearAnswersAskAgain(spoken: String) {
        var session = awaitingApproval()
        let effects = session.handle(.transcript(spoken, isFinal: true))
        #expect(!effects.contains(.answerApproval(true)), "'\(spoken)' approved a destructive call")
        #expect(session.phase == .awaitingApproval, "'\(spoken)' left the gate")
        if !spoken.isEmpty {
            #expect(effects == [.repeatQuestion("Quit Safari? This closes 12 tabs.")],
                    "the question was not put again")
        }
    }

    /// Interim results while someone is still speaking must not resolve anything —
    /// "no" is a prefix of "no wait, yes".
    @Test("An interim answer resolves nothing")
    func interimAnswerIsNotAnAnswer() {
        var session = awaitingApproval()
        #expect(session.handle(.transcript("no", isFinal: false)).isEmpty)
        #expect(session.phase == .awaitingApproval)
        #expect(session.handle(.transcript("no wait yes", isFinal: true))
                == [.repeatQuestion("Quit Safari? This closes 12 tabs.")])
    }

    @Test("Stopping the session while the gate waits does not leave it hanging")
    func stopClearsAPendingApproval() {
        var session = awaitingApproval()
        #expect(session.handle(.stop).contains(.clearAudioQueue))
        #expect(session.phase == .idle)
    }

    // MARK: - Starting and stopping

    @Test("Starting opens the mic ungated; starting twice changes nothing")
    func startIsIdempotent() {
        var session = VoiceSession(hasEchoCancellation: true)
        #expect(session.handle(.start) == [.openMic, .gateMic(false)])
        #expect(session.handle(.start).isEmpty)
        #expect(session.phase == .listening)
    }

    /// A run left going after its only input surface has closed is a run nobody can
    /// stop — the same obligation `cancelPendingPrompts` exists for.
    @Test("Stopping mid-run cancels it rather than leaving it going")
    func stopCancelsAnActiveRun() {
        var session = working()
        let effects = session.handle(.stop)
        #expect(effects == [.cancelRun, .clearAudioQueue, .closeMic])
        #expect(session.phase == .idle)
    }

    @Test("Stopping while idle does nothing, and closing twice is safe")
    func stopIsIdempotent() {
        var session = listening()
        #expect(session.handle(.stop) == [.clearAudioQueue, .closeMic])
        #expect(session.handle(.stop).isEmpty)
    }

    /// Whatever order the inputs arrive in, the gate must agree with the speaker.
    ///
    /// This used to assert only `gated ⇒ phase == .speaking`, and that weakness is what
    /// hid the defect it was meant to catch. The gate guards one physical fact — our own
    /// voice is audible in the room — and the phase is not that fact: narration outlives
    /// the phase it was started in, because `AgentLoop` emits a turn's prose before
    /// running that turn's tools. Half the invariant caught a mic left gated in silence;
    /// nothing caught a mic *opened* onto a sentence still playing, which is the session
    /// cancelling its own run.
    ///
    /// So both directions are asserted, against a model of the speaker kept here from
    /// the effects alone. The single exception is `.awaitingApproval`, which ungates on
    /// purpose so the answer can be heard, and says so in its own comment.
    @Test("The mic is gated exactly while the agent is audible")
    func gateNeverStrandsTheMicrophone() {
        let alphabet: [VoiceSession.Input] = [
            .start, .stop, .speechDetected, .speechEnded,
            .transcript("a word", isFinal: false),
            .transcript("a whole sentence", isFinal: true), .agentStartedWorking,
            .agentWantsToSpeak("something"), .speechFinished, .agentFinished,
            .agentAwaitingApproval("Quit Safari?"), .transcript("yes", isFinal: true),
            .transcript("no", isFinal: true),
        ]
        for echo in [true, false] {
            var session = VoiceSession(hasEchoCancellation: echo)
            var gated = false
            /// The speaker, as the caller would see it: `.speak` and `.repeatQuestion`
            /// start an utterance, `.clearAudioQueue` cuts it off, and `.speechFinished`
            /// is the synthesiser reporting its queue empty.
            var audible = false
            var seed = 1
            for _ in 0..<3_000 {
                // Deterministic, so a failure is reproducible from the seed alone.
                seed = (seed &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
                let input = alphabet[seed % alphabet.count]
                if case .speechFinished = input { audible = false }
                for effect in session.handle(input) {
                    if case let .gateMic(on) = effect { gated = on }
                    if case .closeMic = effect { gated = false }
                    if case .clearAudioQueue = effect { audible = false }
                    if case .speak = effect { audible = true }
                    if case .repeatQuestion = effect { audible = true }
                }
                if gated {
                    #expect(audible && !echo,
                            "mic gated in \(session.phase) with nobody speaking, echo=\(echo)")
                } else if audible && !echo {
                    #expect(session.phase == .awaitingApproval,
                            "mic open onto our own voice in \(session.phase)")
                }
            }
        }
    }
}

/// The microphone is a third TCC grant, and the rule about it is the one this project
/// already applies to Screen Recording: a grant the run will never use is not a reason
/// to call the machine unready.
@Suite("Microphone permission")
struct MicrophonePermissionTests {

    private func status(microphone: Bool) -> PermissionStatus {
        PermissionStatus(screenRecording: true, accessibility: true, microphone: microphone)
    }

    /// The regression this is here to prevent: folding the microphone into `allGranted`
    /// would fail `openclicky doctor && openclicky "…"` on a machine that is entirely
    /// ready for the text run it is about to do.
    @Test("A missing microphone does not make the machine unready for a text run")
    func microphoneIsNotRequiredForOrdinaryRuns() {
        let withoutMic = status(microphone: false)
        #expect(withoutMic.allGranted)
        #expect(withoutMic.isReady(credentials: .working))
        #expect(withoutMic.advice == nil, "a text run was told to grant a microphone")
    }

    @Test("A missing microphone is reported when voice is what is being asked about")
    func voiceAdviceNamesTheThirdGrant() throws {
        let advice = try #require(status(microphone: false).voiceAdvice)
        #expect(advice.contains("Microphone"))
        #expect(advice.contains("third grant"),
                "someone who granted the first two believes they are done")
        #expect(status(microphone: true).voiceAdvice == nil)
    }

    /// `doctor` and the audio engine must not disagree about one grant: a panel saying
    /// "granted" beside a session that hears nothing is worse than either alone.
    @Test("The reported grant comes from the same place the engine reads")
    func statusAgreesWithTheEngine() {
        #expect(PermissionStatus.current().microphone == AudioCapture.isAuthorized)
    }
}

/// The indicator built on these numbers is a level *meter*, not a decoration: a waveform
/// that moves while nobody is talking tells the user the microphone is working when it
/// may not be — the same class of claim as a run reporting success it did not earn.
@Suite("Input level")
struct AudioLevelTests {

    /// A tone at a given amplitude, as the 16-bit PCM the transcriber is actually sent.
    private func pcm(amplitude: Double, samples: Int = 1_600) -> Data {
        var data = Data(capacity: samples * 2)
        for index in 0..<samples {
            let value = sin(Double(index) / 8) * amplitude * Double(Int16.max)
            withUnsafeBytes(of: Int16(max(-32_767, min(32_767, value))).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    @Test("Silence reads as nothing at all")
    func silenceIsZero() {
        #expect(AudioCapture.loudness(of: Data(count: 3_200)) == 0)
        #expect(AudioCapture.loudness(of: Data()) == 0)
        #expect(AudioCapture.loudness(of: Data([0x01])) == 0, "a partial sample is not a level")
    }

    /// Quieter than the floor is a room, not a voice. Letting it show would make the
    /// indicator twitch continuously at nothing, which is the decorative failure.
    @Test("Room noise below the floor reads as nothing")
    func roomNoiseIsBelowTheFloor() {
        #expect(AudioCapture.loudness(of: pcm(amplitude: 0.001)) == 0)
    }

    @Test("Speech-level audio registers, and louder reads louder")
    func louderReadsLouder() {
        let quiet = AudioCapture.loudness(of: pcm(amplitude: 0.02))
        let normal = AudioCapture.loudness(of: pcm(amplitude: 0.2))
        let loud = AudioCapture.loudness(of: pcm(amplitude: 0.9))
        #expect(quiet > 0, "speech at a normal distance must not read as silence")
        #expect(quiet < normal)
        #expect(normal < loud)
    }

    /// A bar chart cannot show a value outside its own range, and a meter that pins or
    /// goes negative is worse than one that saturates.
    @Test("The level always stays inside 0…1", arguments: [0.0, 0.001, 0.05, 0.5, 1.0])
    func levelStaysInRange(amplitude: Double) {
        let level = AudioCapture.loudness(of: pcm(amplitude: amplitude))
        #expect(level >= 0 && level <= 1, "\(amplitude) produced \(level)")
    }

    /// Logarithmic, not linear. Speech at a normal distance is around -30 dBFS, which is
    /// a linear RMS of 0.03 — indistinguishable from silence on a bar chart, which is why
    /// a linear meter looks broken.
    @Test("The scale is logarithmic, so ordinary speech is visible")
    func scaleIsLogarithmic() {
        let level = AudioCapture.loudness(of: pcm(amplitude: 0.03))
        #expect(level > 0.15, "ordinary speech barely moved the meter: \(level)")
    }
}
