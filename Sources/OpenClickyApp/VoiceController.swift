import Foundation
import OSLog
import OpenClickyKit

/// Runs a voice session against the surfaces this app already has.
///
/// Glue, and deliberately nothing but glue: every rule about who holds the floor lives
/// in `VoiceSession`, which is a value type with no device, no socket and no window, and
/// is tested as such. What is left here is the mapping from its effects onto the
/// microphone, the transcriber, and the two entry points the typed interface already
/// uses — which is exactly the part a test could not reach anyway.
///
/// The most important line in the file is `.cancelRun` becoming `onCancel`, which the
/// delegate wires to `handleEscape()`. That is the single cancellation path: it stops
/// the run *and* answers whatever approval or question the loop is suspended inside.
/// Barge-in that built its own way to stop a run would be a second path carrying the
/// same obligation, and the first one exists because forgetting it hangs the loop.
@MainActor
final class VoiceController {

    /// What the session needs from the app. Closures rather than a delegate reference
    /// so this cannot reach for anything it was not handed.
    struct Surfaces {
        let submit: (String) -> Void
        let cancel: () -> Void
        let answerApproval: (Bool) -> Void
        let speak: (String) -> Void
        let clearAudio: () -> Void
        let report: (String) -> Void
        /// Called whenever the floor changes hands, so a surface can show it.
        let phaseChanged: (VoiceSession.Phase?, String) -> Void
        /// Called with the loudness of what the microphone is actually sending.
        let levelChanged: (Float) -> Void
    }

    private(set) var session = VoiceSession()
    private let capture = AudioCapture()
    /// Built once and kept. `AVSpeechSynthesizer` holds an audio route, and constructing
    /// one per utterance costs a device setup that is audible as a gap in front of every
    /// sentence — in front of narration, which is spoken while the user waits for an
    /// action, that gap is the whole difference this phase is trying to make.
    private lazy var synthesizer: any SpeechSynthesizer = SystemSpeechSynthesizer { [weak self] in
        Task { @MainActor in self?.speechFinished() }
    }
    private var transcriber: (any SpeechTranscriber)?
    /// The pending settle timer, or nil when no turn is waiting to close.
    ///
    /// The one piece of `VoiceSession`'s alphabet that needs a clock, which is exactly
    /// why it is here and not there: the session stays a value type that a test can
    /// drive by handing it `.endOfTurn`, and what a real second feels like is the
    /// controller's problem. Cancelled before it is replaced, so speech that keeps
    /// arriving keeps pushing the deadline out rather than stacking alarms behind it.
    private var settleTimer: Task<Void, Never>?
    /// Says that the wait is still going, for a wait that outlasts the opener.
    ///
    /// The clock the other half of `VoiceFiller` needs, here for the same reason the
    /// settle timer is: `VoiceSession` decides *what* is said and when the floor is
    /// free to say it, and what a real seven seconds feels like is not a rule a value
    /// type can hold.
    private var holdTimer: Task<Void, Never>?
    /// How many holds this wait has already spoken, so they do not repeat.
    private var holdsSpoken = 0
    /// Says what the agent is doing when the agent itself did not.
    ///
    /// Held here rather than in `VoiceSession` because it is not a rule about who holds
    /// the floor — everything it produces still goes through the session, which is what
    /// refuses to talk over someone mid-sentence.
    private var commentary = ActionCommentary()
    /// Whether a run is in flight.
    ///
    /// Not read off `session.phase`, and the difference matters: the phase leaves
    /// `.working` the moment the agent says anything, and does not come back until the
    /// next turn starts — so a hold spoken at seven seconds would have taken the run's
    /// own state away and silenced every hold after it. This is a fact about the agent,
    /// which is exactly what the phase is not.
    private var isAgentWorking = false
    /// The one route from the microphone tap to the socket. See `start(config:)`.
    private var audioFrames: AsyncStream<Data>.Continuation?
    private let surfaces: Surfaces

    private(set) var isRunning = false
    /// Whether `start()` is partway through bringing a session up. See the guard there.
    private var isStarting = false

    init(surfaces: Surfaces) {
        self.surfaces = surfaces
    }

    /// Opens the microphone and the transcript stream.
    ///
    /// Failures are reported rather than thrown onward: this is started from a menu
    /// item, and the two things that realistically go wrong — no microphone grant, no
    /// key for the chosen vendor — are both fixed by the user rather than by the code,
    /// so they need to reach a surface with words on it.
    ///
    /// Which vendor is a stored choice, read here rather than compiled in. This layer
    /// used to name `DeepgramTranscriber` directly, which gave up the whole point of the
    /// `SpeechTranscriber` seam and left the app with one hard-wired vendor whose key
    /// could not be stored by any command that existed.
    func start(config: ConfigFile = ConfigFile()) async {
        // `isRunning` is not set until the socket and the engine are both up, four
        // `await`s below — so it cannot be the only guard. A second click of the menu
        // item during the handshake found `isRunning == false`, re-entered, overwrote
        // `transcriber` (leaking the first socket, never finished) and called
        // `capture.start()` on an engine that already had a tap installed on bus 0 —
        // which AVAudioEngine answers with an Objective-C exception Swift cannot catch.
        //
        // Both lines are `@MainActor` with no suspension between them, so this closes
        // the window that `isRunning` alone leaves open.
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        // Split rather than `||`: the right-hand side is async, and `||` short-circuits
        // through an autoclosure that cannot await.
        var authorized = AudioCapture.isAuthorized
        if !authorized { authorized = await AudioCapture.requestAccess() }
        guard authorized else {
            surfaces.report(PermissionStatus.current().voiceAdvice ?? "No microphone access.")
            return
        }

        let provider = VoiceProvider.stored((try? config.settings()) ?? .init())
        let transcriber: (any SpeechTranscriber)?
        do {
            transcriber = try provider.transcriber(config: config)
        } catch {
            surfaces.report("\(error)")
            return
        }
        guard let transcriber else {
            surfaces.report("\(MissingVoiceCredentials(provider))")
            return
        }
        self.transcriber = transcriber

        do {
            try await transcriber.start { [weak self] event in
                Task { @MainActor in self?.receive(event) }
            }
        } catch {
            surfaces.report("\(error)")
            self.transcriber = nil
            return
        }

        // One queue between the microphone and the socket, rather than a `Task` per
        // buffer.
        //
        // The tap fires around 22 times a second and used to spawn an unstructured
        // `Task` for each one. Separate tasks awaiting the same actor are not FIFO —
        // nothing in the concurrency model orders them — so a frame could reach the
        // socket after its successor, and both vendors read that socket as a positional
        // byte stream: reordered PCM decodes as noise, confidently transcribed, which is
        // the same silent failure `AudioCapture`'s channel map was written for. It also
        // allocated on the real-time audio thread, which the tap's own documentation
        // forbids.
        //
        // A stream with one consumer gives the frames a single order and makes the
        // tap's side of it a non-blocking `yield`. `.bufferingNewest(32)` — about a
        // second and a half of audio — because if the socket ever falls that far behind,
        // the newest speech is what a recogniser can still use; an unbounded queue would
        // grow for as long as the session lasts and transcribe a conversation that ended
        // minutes ago.
        let (frames, continuation) = AsyncStream<Data>.makeStream(
            of: Data.self, bufferingPolicy: .bufferingNewest(32)
        )
        audioFrames = continuation
        // Captured strongly because `any SpeechTranscriber` is not class-bound and
        // cannot be held weakly. The loop ends when `.closeMic` finishes the
        // continuation, so the reference does not outlive the session.
        Task { [transcriber] in
            for await buffer in frames { await transcriber.send(buffer) }
        }

        do {
            // The rate the vendor was told to expect, not a constant: `pcm16` means
            // 24 kHz to OpenAI and Deepgram is told 16 kHz in its query string, and
            // either one fed the other's rate transcribes noise rather than failing.
            try capture.start(sampleRate: transcriber.sampleRate, onBuffer: { audio in
                // The only thing the audio thread does with the buffer: hand it over.
                // No allocation, no await, no reordering.
                continuation.yield(audio)
            }, onLevel: { [weak self] level in
                Task { @MainActor in self?.surfaces.levelChanged(level) }
            }, onProblem: { [weak self] problem in
                // The session is not torn down: the socket is fine, and the device may
                // come back when the user switches input. What it must not do is carry
                // on looking healthy — a mic that is open and deaf is the failure this
                // whole watchdog exists to stop being invisible.
                Task { @MainActor in self?.surfaces.report("\(problem)") }
            })
        } catch {
            surfaces.report("\(error)")
            // Finished here too, or the consumer task above outlives a session that
            // never opened and holds the transcriber alive with it.
            continuation.finish()
            audioFrames = nil
            await transcriber.finish()
            self.transcriber = nil
            return
        }

        // Rebuilt now rather than at init, because whether the device cancels our own
        // output is only known once the engine has started — and a session that assumed
        // wrongly either cancels its own runs or cannot be interrupted mid-sentence.
        session = VoiceSession(hasEchoCancellation: capture.hasEchoCancellation)
        // Recorded because every difference it makes is invisible from the outside: a
        // session that cannot be interrupted mid-sentence and one that can look
        // identical until you try. Once per session, at start, so a report of "it
        // stopped listening to me" has something to be checked against.
        let echo = capture.hasEchoCancellation ? "on" : "off"
        Logger(subsystem: "com.openclicky", category: "voice")
            .notice("session started; echo cancellation \(echo, privacy: .public)")
        isRunning = true
        apply(session.handle(.start))
    }

    func stop() {
        guard isRunning else { return }
        apply(session.handle(.stop))
    }

    // MARK: - Feeding the session

    private func receive(_ event: TranscriptEvent) {
        switch event {
        case .speechDetected:
            apply(session.handle(.speechDetected))
        case .speechEnded:
            apply(session.handle(.speechEnded))
        case let .transcript(text, isFinal):
            apply(session.handle(.transcript(text, isFinal: isFinal)))
        case let .failed(detail):
            // The session **is** torn down, and the comment that used to sit here
            // promised a reconnect that was never written. What actually happened: the
            // transcriber actor sets its own `isRunning = false` before emitting this,
            // so every buffer after it is dropped by the actor — while this controller
            // stayed `isRunning`, the engine kept running, the menu still offered "Stop
            // Voice Session", narration kept being written for a listener, and the level
            // meter kept bouncing at the user's voice.
            //
            // That last part is the worst of it. `AudioCapture.onLevel`'s own contract
            // says a waveform that moves while nothing is being heard "tells the user the
            // microphone is working when it may not be" — and here it was vouching for a
            // socket that had already hung up. A session that has lost its transcriber is
            // not a session; ending it is what makes the failure legible.
            surfaces.report("Transcription stopped: \(detail)")
            apply(session.handle(.stop))
        }
    }

    /// Whether the agent's prose should be written for a listener.
    ///
    /// Read by `AgentLoop` at the top of every turn, so starting a voice session
    /// mid-conversation changes how the *next* turn is written without rebuilding
    /// anything or losing the thread.
    var isNarrating: Bool { isRunning }

    /// Speaks a turn's prose, if there is anything in it worth saying out loud.
    ///
    /// The agent already narrates: the system prompt has always told it to say what it
    /// is about to do before doing it, and `AgentLoop` emits `.assistantText` before it
    /// executes that turn's tool calls. So the ordering the epic asks for — speak, then
    /// act, then speak, then act — is what the loop already does, one turn at a time.
    /// What was missing was a speaker and a translation from written prose to spoken.
    func narrate(_ prose: String) {
        guard isRunning, let text = Narration.speakable(prose) else { return }
        // Recorded only where the prose actually reached a speaker. A turn that was
        // entirely a code block reduces to nothing, and counting that as narration
        // would suppress the commentary that is the only thing left to fill the silence.
        commentary.narrated()
        // The wait is over as far as the listener is concerned — something with
        // information in it has arrived. Restarted rather than stopped, because the
        // turn after this one may be just as slow, and "still going" is still the right
        // thing to say seven seconds into it.
        apply(session.handle(.agentWantsToSpeak(text)))
        if isAgentWorking { beginWaiting() }
    }

    /// Starts saying that a wait is still going, once it has gone on long enough.
    ///
    /// The silence this covers is not a cosmetic one. A spoken session that goes quiet
    /// does not read as "working" — it reads as "it did not hear me", so the sentence
    /// gets said again, and saying it again is barge-in: it cancels the run that was
    /// about to answer. A wait nobody narrates is a wait that gets interrupted.
    private func beginWaiting() {
        holdTimer?.cancel()
        holdsSpoken = 0
        holdTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(VoiceFiller.patience))
                guard !Task.isCancelled, let self, self.isRunning, self.isAgentWorking else {
                    return
                }
                let line = VoiceFiller.hold(after: self.holdsSpoken)
                self.holdsSpoken += 1
                // Through the session, not straight at the synthesiser: it is what
                // refuses to talk over someone who is mid-sentence, and a filler is the
                // least important thing in the room to interrupt a user with.
                self.apply(self.session.handle(.agentWantsToSpeak(line)))
            }
        }
    }

    private func endWaiting() {
        holdTimer?.cancel()
        holdTimer = nil
        holdsSpoken = 0
    }

    /// The agent's own events, so the session knows who holds the floor.
    func agentStartedWorking() {
        isAgentWorking = true
        commentary.turnBegan()
        apply(session.handle(.agentStartedWorking))
        beginWaiting()
    }

    /// Announces a tool that is about to run, if the model left the turn silent.
    ///
    /// The floor under narration, and the reason a run against `gpt-4.1` said nothing
    /// between its opener and its closing paragraph: that model answers a decision to
    /// act with the tool call alone, no prose, so there was nothing for `narrate` to
    /// say. What this speaks is the call *this process is about to make* — never what
    /// was found, which stays the model's to report.
    func announceAction(_ tool: String) {
        guard isRunning else { return }
        // **Silence is the price of hearing, on a device that cannot cancel its own
        // output.** Where `setVoiceProcessingEnabled` is refused, `VoiceSession` gates
        // the microphone for the length of every utterance — and `AudioCapture.gated`
        // drops the buffers rather than merely discarding the transcript, so the
        // session is genuinely deaf while it talks. A sentence per tool call, at the
        // rate a run makes them, would spend most of the run deaf.
        //
        // That is the wrong trade here and only here. The opener is the receipt for
        // having heard the instruction, the holds say a wait is still going, and the
        // model's own narration is the account of what is happening — all three carry
        // something. "Clicking." does not carry enough to be worth not hearing "stop"
        // over, and being stoppable is the complaint this whole branch started from.
        guard session.hasEchoCancellation else { return }
        guard let line = commentary.announcing(tool: tool) else { return }
        apply(session.handle(.agentWantsToSpeak(line)))
        // A said action is a said thing: the wait starts again from here, so a long
        // tool call gets its own "still going" rather than inheriting the last one's.
        if isAgentWorking { beginWaiting() }
    }

    func agentFinished() {
        isAgentWorking = false
        endWaiting()
        apply(session.handle(.agentFinished))
    }

    func agentWantsToSpeak(_ text: String) { apply(session.handle(.agentWantsToSpeak(text))) }
    func agentAwaitingApproval(_ question: String) {
        apply(session.handle(.agentAwaitingApproval(question)))
    }
    func speechFinished() { apply(session.handle(.speechFinished)) }

    // MARK: - Performing effects

    private func apply(_ effects: [VoiceSession.Effect]) {
        defer {
            // One place, after the effects rather than inside them: the phase is a
            // property of the session, and reporting it per effect would announce
            // intermediate states that never existed.
            surfaces.phaseChanged(isRunning ? session.phase : nil, session.heard)
        }
        for effect in effects {
            switch effect {
            case .openMic:
                break // The engine is already running; `start` opened it.
            case .closeMic:
                settleTimer?.cancel()
                settleTimer = nil
                isAgentWorking = false
                endWaiting()
                synthesizer.stop()
                capture.stop()
                // After the tap is removed, so nothing yields into a finished stream,
                // and before `finish()`, so the consumer drains what it already holds
                // rather than leaving the loop suspended on a closed session.
                audioFrames?.finish()
                audioFrames = nil
                let closing = transcriber
                transcriber = nil
                isRunning = false
                Task { await closing?.finish() }
            case let .gateMic(on):
                capture.gated = on
            case .cancelRun:
                // The run is over, so there is nothing left to be patient about. Left
                // armed, the next hold would announce that a cancelled run was still
                // going — a filler is the one thing here that can claim work is
                // happening when it is not.
                isAgentWorking = false
                endWaiting()
                surfaces.cancel()
            case .clearAudioQueue:
                // Before the cancel reaches the loop, not after. A user who talks over
                // the agent and then hears the sentence finish anyway has been told
                // plainly that interrupting does not work.
                synthesizer.stop()
                surfaces.clearAudio()
            case let .speak(text):
                // Returns immediately: speech happens on the synthesiser's own thread,
                // which is what lets the agent click and type while it is still talking.
                synthesizer.speak(text)
                surfaces.speak(text)
            case .armEndOfTurn:
                settleTimer?.cancel()
                settleTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(VoiceSession.settle))
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.settleTimer = nil
                    self.apply(self.session.handle(.endOfTurn))
                }
            case .disarmEndOfTurn:
                settleTimer?.cancel()
                settleTimer = nil
            case let .submit(task):
                surfaces.submit(task)
            case let .answerApproval(approved):
                surfaces.answerApproval(approved)
            case let .repeatQuestion(question):
                // Said again rather than guessed at. Prefixed so a second hearing of the
                // same sentence reads as "I did not understand you" rather than as the
                // agent having got stuck.
                //
                // **Spoken, not merely written.** This branch called `surfaces.speak`
                // alone, which is `activity.record(instruction:)` — a text mirror for a
                // panel. The one path in the whole stack where the user is hands-free at
                // a destructive permission gate, having just said something the approval
                // grammar could not read, produced no sound at all: the gate stayed
                // parked, the session stayed in `.awaitingApproval`, and the only way to
                // learn any of that was to look at the screen this feature exists to let
                // them ignore. `VoiceSession`'s own note — "one denied by a mishearing,
                // silently, leaves the user believing they were ignored" — described what
                // the app did.
                let reask = question.isEmpty
                    ? "Sorry, I did not catch that."
                    : "Sorry, I did not catch that. \(question)"
                synthesizer.speak(reask)
                surfaces.speak(reask)
            }
        }
    }
}
