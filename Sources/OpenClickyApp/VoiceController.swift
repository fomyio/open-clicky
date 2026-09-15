import Foundation
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
    private let surfaces: Surfaces

    private(set) var isRunning = false

    init(surfaces: Surfaces) {
        self.surfaces = surfaces
    }

    /// Opens the microphone and the transcript stream.
    ///
    /// Failures are reported rather than thrown onward: this is started from a menu
    /// item, and the two things that realistically go wrong — no microphone grant, no
    /// Deepgram key — are both fixed by the user rather than by the code, so they need
    /// to reach a surface with words on it.
    func start(config: ConfigFile = ConfigFile()) async {
        guard !isRunning else { return }

        // Split rather than `||`: the right-hand side is async, and `||` short-circuits
        // through an autoclosure that cannot await.
        var authorized = AudioCapture.isAuthorized
        if !authorized { authorized = await AudioCapture.requestAccess() }
        guard authorized else {
            surfaces.report(PermissionStatus.current().voiceAdvice ?? "No microphone access.")
            return
        }

        let transcriber: (any SpeechTranscriber)?
        do {
            transcriber = try DeepgramTranscriber.stored(config: config)
        } catch {
            surfaces.report("\(error)")
            return
        }
        guard let transcriber else {
            surfaces.report("\(DeepgramTranscriber.Error.missingCredentials)")
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

        do {
            try capture.start(onBuffer: { [transcriber] audio in
                // Detached from the audio thread deliberately: the tap must not block,
                // and a socket send is I/O.
                //
                // Captured strongly because `any SpeechTranscriber` is not class-bound
                // and cannot be held weakly. That is safe in the one direction it needs
                // to be: `.closeMic` removes the tap before it drops its reference, so
                // the closure stops being called before the transcriber would go away,
                // and a buffer arriving after `finish()` is dropped by the actor rather
                // than reaching a dead socket.
                Task { await transcriber.send(audio) }
            }, onLevel: { [weak self] level in
                Task { @MainActor in self?.surfaces.levelChanged(level) }
            })
        } catch {
            surfaces.report("\(error)")
            await transcriber.finish()
            self.transcriber = nil
            return
        }

        // Rebuilt now rather than at init, because whether the device cancels our own
        // output is only known once the engine has started — and a session that assumed
        // wrongly either cancels its own runs or cannot be interrupted mid-sentence.
        session = VoiceSession(hasEchoCancellation: capture.hasEchoCancellation)
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
        case let .transcript(text, isFinal):
            apply(session.handle(.transcript(text, isFinal: isFinal)))
        case let .failed(detail):
            // The session is not torn down. A dropped socket is a reconnect, and a run
            // in flight is not this layer's to cancel — but going quiet without saying
            // why is how a user concludes the microphone is broken.
            surfaces.report("Transcription stopped: \(detail)")
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
        apply(session.handle(.agentWantsToSpeak(text)))
    }

    /// The agent's own events, so the session knows who holds the floor.
    func agentStartedWorking() { apply(session.handle(.agentStartedWorking)) }
    func agentFinished() { apply(session.handle(.agentFinished)) }
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
                synthesizer.stop()
                capture.stop()
                let closing = transcriber
                transcriber = nil
                isRunning = false
                Task { await closing?.finish() }
            case let .gateMic(on):
                capture.gated = on
            case .cancelRun:
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
            case let .submit(task):
                surfaces.submit(task)
            case let .answerApproval(approved):
                surfaces.answerApproval(approved)
            case let .repeatQuestion(question):
                // Said again rather than guessed at. Prefixed so a second hearing of the
                // same sentence reads as "I did not understand you" rather than as the
                // agent having got stuck.
                surfaces.speak(question.isEmpty
                    ? "Sorry, I did not catch that."
                    : "Sorry, I did not catch that. \(question)")
            }
        }
    }
}
