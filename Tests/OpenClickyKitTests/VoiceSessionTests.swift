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

    // MARK: - Barge-in

    /// The whole feature. Cancelling *and* clearing the queue: stopping the generation
    /// while the last sentence keeps playing is the failure that reads as the assistant
    /// ignoring you.
    @Test("Speaking while the agent works stops it and empties the audio queue")
    func speechDuringWorkCancels() {
        var session = working()
        let effects = session.handle(.speechDetected)
        #expect(effects.contains(.cancelRun))
        #expect(effects.contains(.clearAudioQueue))
        #expect(session.phase == .hearing)
    }

    @Test("Speaking over the agent's own speech interrupts it too")
    func speechDuringSpeechCancels() {
        var session = speaking()
        let effects = session.handle(.speechDetected)
        #expect(effects.contains(.cancelRun))
        #expect(effects.contains(.clearAudioQueue))
        #expect(session.phase == .hearing)
    }

    /// Detection is the earliest signal there is, and barge-in has to use it. Waiting
    /// for words puts a sentence of latency between "the user started talking over it"
    /// and "it stopped".
    @Test("Interruption needs only detection, not a transcript")
    func bargeInDoesNotWaitForWords() {
        var session = working()
        #expect(session.handle(.speechDetected).contains(.cancelRun))
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

    /// The regression `gateNeverStrandsTheMicrophone` found, pinned as its own case so
    /// a failure names the sequence rather than a seed. This is Phase 4's normal flow —
    /// say what you are about to do, then do it — and it left the transcript gated for
    /// the whole of the work, so the mic was deaf during exactly the part a user most
    /// wants to interrupt.
    @Test("Starting work mid-sentence lifts the gate rather than staying deaf")
    func workingAfterSpeakingLiftsTheGate() {
        var session = speaking(echoCancelled: false)
        #expect(session.handle(.agentStartedWorking).contains(.gateMic(false)))
        #expect(session.phase == .working)
        // And barge-in works again immediately, which is the point of lifting it.
        #expect(session.handle(.speechDetected).contains(.cancelRun))
    }

    @Test("The gate is lifted again when the agent stops talking")
    func gateLiftsAfterSpeaking() {
        var session = speaking(echoCancelled: false)
        #expect(session.handle(.speechFinished).contains(.gateMic(false)))
        #expect(session.phase == .listening)
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

    @Test("A finished utterance is submitted as a task, trimmed")
    func finalTranscriptBecomesATask() {
        var session = listening()
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("open my", isFinal: false))
        let effects = session.handle(.transcript("  open my calendar  ", isFinal: true))
        #expect(effects == [.submit("open my calendar")])
        #expect(session.phase == .listening)
    }

    /// The interim text is a running guess at the same span, not a prefix to be
    /// concatenated. Appending would double every sentence.
    @Test("Interim text is replaced by the final, never appended to it")
    func interimIsNotConcatenated() {
        var session = listening()
        _ = session.handle(.transcript("open", isFinal: false))
        _ = session.handle(.transcript("open my cal", isFinal: false))
        #expect(session.handle(.transcript("open my calendar", isFinal: true))
                == [.submit("open my calendar")])
    }

    @Test("What is being heard is visible, and cleared once it is used")
    func interimTextIsExposedAndCleared() {
        var session = listening()
        _ = session.handle(.transcript("open my cal", isFinal: false))
        #expect(session.heard == "open my cal")
        _ = session.handle(.transcript("open my calendar", isFinal: true))
        #expect(session.heard.isEmpty, "the last utterance lingered as though current")
    }

    /// Barge-in and the next instruction are one gesture: you interrupt *by* saying the
    /// thing you want instead.
    @Test("An interruption's own words become the next task")
    func interruptionCarriesTheNextInstruction() {
        var session = working()
        _ = session.handle(.speechDetected)
        #expect(session.handle(.transcript("no, open Safari instead", isFinal: true))
                == [.submit("no, open Safari instead")])
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

    /// The user must be able to stop a narration they have heard enough of, and stopping
    /// it has to silence the audio as well as the run.
    @Test("Talking over a narration silences it and cancels the run")
    func narrationIsInterruptible() {
        var session = working()
        _ = session.handle(.agentWantsToSpeak("Here is a long explanation nobody asked for"))
        let effects = session.handle(.speechDetected)
        #expect(effects.contains(.clearAudioQueue))
        #expect(effects.contains(.cancelRun))
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
        #expect(session.handle(.transcript("yes", isFinal: true)) == [.answerApproval(true)])
        #expect(session.phase == .working)

        var refusing = awaitingApproval()
        #expect(refusing.handle(.transcript("no", isFinal: true)) == [.answerApproval(false)])
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

    /// Whatever order the inputs arrive in, the session must not end up believing the
    /// agent is speaking when it is not — that state gates the microphone.
    @Test("No sequence of inputs leaves the mic gated with nobody speaking")
    func gateNeverStrandsTheMicrophone() {
        let alphabet: [VoiceSession.Input] = [
            .start, .stop, .speechDetected, .transcript("a word", isFinal: false),
            .transcript("a whole sentence", isFinal: true), .agentStartedWorking,
            .agentWantsToSpeak("something"), .speechFinished, .agentFinished,
            .agentAwaitingApproval("Quit Safari?"), .transcript("yes", isFinal: true),
            .transcript("no", isFinal: true),
        ]
        for echo in [true, false] {
            var session = VoiceSession(hasEchoCancellation: echo)
            var gated = false
            var seed = 1
            for _ in 0..<3_000 {
                // Deterministic, so a failure is reproducible from the seed alone.
                seed = (seed &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
                for effect in session.handle(alphabet[seed % alphabet.count]) {
                    if case let .gateMic(on) = effect { gated = on }
                    if case .closeMic = effect { gated = false }
                }
                if gated {
                    #expect(session.phase == .speaking,
                            "mic gated in \(session.phase) with echo=\(echo)")
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
