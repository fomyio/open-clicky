import Testing
import Foundation
@testable import OpenClickyKit

/// Acting on a sentence before it is finished, and the four rules that make that safe.
///
/// This is the one place in the session where something other than the person causes an
/// action, and it happens *while they are still talking*. Every test here is a limit:
/// the same instruction is not carried out twice, a word the transcriber has not
/// committed to is not acted on, an answer to a permission question is never a task, and
/// nothing survives the turn it belonged to.
@Suite("Fast turns")
struct FastTurnTests {

    private func listening() -> VoiceSession {
        var session = VoiceSession(hasEchoCancellation: true)
        _ = session.handle(.start)
        return session
    }

    private func listening(hasFastPath: Bool) -> VoiceSession {
        var session = VoiceSession(hasEchoCancellation: true, hasFastPath: hasFastPath)
        _ = session.handle(.start)
        return session
    }

    private let safari = FastPath.Action.activate(bundleIdentifier: "com.apple.Safari")
    private let notes = FastPath.Action.activate(bundleIdentifier: "com.apple.Notes")

    private func reading(
        _ utterance: String,
        action: FastPath.Action,
        addressed: Double = 0.99,
        complete: Double = 0.99
    ) -> TurnReading {
        TurnReading(
            utterance: utterance, addressed: addressed, complete: complete,
            halt: 0.01, intent: .instruction, intentConfidence: 0.9, action: action
        )
    }

    private func submitted(in effects: [VoiceSession.Effect]) -> SpokenTask? {
        for effect in effects {
            if case let .submit(task) = effect { return task }
        }
        return nil
    }

    private func asked(in effects: [VoiceSession.Effect]) -> [String] {
        effects.compactMap {
            if case let .classify(context) = $0 { return context.utterance } else { return nil }
        }
    }

    // MARK: - The cadence

    /// Windows of 1–3, 1–6, 1–9: the whole sentence each time, not the new words. Three
    /// words in isolation have lost the verb, and the questions being asked are about
    /// the sentence.
    @Test("Readings are asked for on cumulative prefixes as the sentence grows")
    func cadenceAsksOnGrowingPrefixes() {
        var session = listening()
        _ = session.handle(.speechDetected)

        #expect(asked(in: session.handle(.transcript("open", isFinal: false))).isEmpty,
                "a reading was bought for one word")
        #expect(asked(in: session.handle(.transcript("open the settings", isFinal: false)))
                == ["open the settings"])
        // Two more words is not yet another window.
        #expect(asked(in: session.handle(.transcript("open the settings app now", isFinal: false)))
                .isEmpty)
        #expect(asked(in: session.handle(
            .transcript("open the settings app now and then", isFinal: false)
        )) == ["open the settings app now and then"],
                "the next window asked about the fragment instead of the sentence")
    }

    @Test("A settled segment always asks, whatever the word count")
    func settledSegmentsAlwaysAsk() {
        var session = listening()
        #expect(asked(in: session.handle(.transcript("stop that", isFinal: true)))
                == ["stop that"])
    }

    // MARK: - Acting, and what has to be true first

    /// Settled text will not be revised, so there is nothing left to confirm.
    @Test("An action named on settled text is carried out at once")
    func settledTextActsImmediately() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))

        let task = submitted(in: session.handle(.classified(reading("open Safari", action: safari))))
        #expect(task?.opening == [safari])
        #expect(task?.concludesTask == true)
        #expect(task?.text == "open Safari")
    }

    /// A fast turn that sounds like a slow one is worse than either. `VoiceFiller` fills
    /// the silence while a model thinks, and there is no model here — the receipt would
    /// still be playing when the thing it promised had happened.
    @Test("A turn done without a model is not preceded by an opener")
    func noOpenerOnTheFastPath() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        let effects = session.handle(.classified(reading("open Safari", action: safari)))
        #expect(!effects.contains { if case .speak = $0 { return true } else { return false } },
                "the session promised to do something it had already done")
    }

    /// The retraction this prevents is real: "open sat" is a plausible prefix of "open
    /// Saturday's notes" and of "open Safari", and a vendor revises interims freely.
    @Test("An action named on unsettled text waits for a second window to agree")
    func interimTextNeedsConfirming() {
        var session = listening()
        _ = session.handle(.transcript("open Safari now", isFinal: false))

        let first = session.handle(.classified(reading("open Safari now", action: safari)))
        #expect(submitted(in: first) == nil, "a word the transcriber had not committed to was acted on")

        _ = session.handle(.transcript("open Safari now please if you would", isFinal: false))
        let second = session.handle(.classified(
            reading("open Safari now please if you would", action: safari)
        ))
        #expect(submitted(in: second)?.opening == [safari], "two windows agreed and nothing happened")
    }

    /// Two readings naming different actions are not weak evidence for either — they are
    /// evidence the sentence is still changing underneath.
    @Test("Two windows that disagree start the count over")
    func disagreementResetsTheCount() {
        var session = listening()
        _ = session.handle(.transcript("open something", isFinal: false))
        _ = session.handle(.classified(reading("open something", action: safari)))
        _ = session.handle(.transcript("open something else entirely", isFinal: false))
        _ = session.handle(.classified(reading("open something else entirely", action: notes)))
        // Two readings so far, but never the same one twice.
        #expect(submitted(in: session.handle(.classified(
            reading("open something else entirely", action: safari)
        ))) == nil, "a disagreement was counted as agreement")
    }

    /// A reading that names no action at all is not neutral — it is evidence the
    /// sentence has changed into something else, and what was agreed before it no longer
    /// describes what is being said.
    @Test("A window that names no action clears what was agreed before it")
    func aNonActionResetsTheCount() {
        var session = listening()
        _ = session.handle(.transcript("open something", isFinal: false))
        _ = session.handle(.classified(reading("open something", action: safari)))

        _ = session.handle(.transcript("open something quite different now", isFinal: false))
        _ = session.handle(.classified(
            reading("open something quite different now", action: .model)
        ))

        _ = session.handle(.transcript("open something quite different now indeed", isFinal: false))
        #expect(submitted(in: session.handle(.classified(
            reading("open something quite different now indeed", action: safari)
        ))) == nil, "agreement survived a window that named no action at all")
    }

    // MARK: - Not doing it twice

    /// The windows overlap by construction — 1–3, 1–6, 1–9 all contain "open Safari" —
    /// so this is the ordinary case rather than an edge one.
    @Test("The same instruction inside three windows is carried out once")
    func anInstructionInsideEveryWindowFiresOnce() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        #expect(submitted(in: session.handle(.classified(reading("open Safari", action: safari)))) != nil)

        _ = session.handle(.transcript("open Safari please", isFinal: true))
        #expect(submitted(in: session.handle(.classified(
            reading("open Safari open Safari please", action: safari)
        ))) == nil, "the app was brought forward twice for one sentence")
    }

    /// Keyed on the action, not the words — so a second, different request in the same
    /// breath still happens.
    @Test("A different action later in the same sentence still happens")
    func aSecondDifferentActionStillFires() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        _ = session.handle(.classified(reading("open Safari", action: safari)))

        _ = session.handle(.transcript("and Notes", isFinal: true))
        #expect(submitted(in: session.handle(
            .classified(reading("open Safari and Notes", action: notes))
        ))?.opening == [notes])
    }

    // MARK: - Where it must never fire

    /// The loop is parked inside `PermissionGate` waiting on an answer. Starting a run
    /// there leaves the gate suspended forever while a second one begins on top of it.
    @Test("An answer to a permission question is never taken as a task")
    func neverFiresWhileTheGateWaits() {
        var session = listening()
        _ = session.handle(.agentStartedWorking)
        _ = session.handle(.agentAwaitingApproval("Delete 12 files?"))

        // Twice, so the confirmation rule is satisfied and the phase is the *only*
        // thing left standing between this and a second run. Asserted once would have
        // passed on the count alone and proved nothing about the gate.
        _ = session.handle(.classified(reading("yes go ahead", action: safari)))
        #expect(submitted(in: session.handle(
            .classified(reading("yes go ahead", action: safari))
        )) == nil, "a run was started while the gate held a destructive call")
    }

    @Test("A remark meant for somebody else is never carried out")
    func neverFiresOnAnOverheardTurn() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        #expect(submitted(in: session.handle(
            .classified(reading("open Safari", action: safari, addressed: 0.01))
        )) == nil)
    }

    /// "Open Safari" reads complete at word two; "open Safari and then check my—" does
    /// not. Without this, one sentence becomes two runs.
    @Test("Half a sentence is never carried out")
    func neverFiresOnHalfASentence() {
        var session = listening()
        _ = session.handle(.transcript("open Safari and then", isFinal: true))
        #expect(submitted(in: session.handle(
            .classified(reading("open Safari and then", action: safari, complete: 0.02))
        )) == nil)
    }

    // MARK: - What the end of the turn does with it

    /// Not the rule about never swallowing what somebody said — that rule is about turns
    /// going unheard, and this one was heard, understood, and acted on before the
    /// speaker finished saying it.
    @Test("A turn already carried out is not submitted again when it ends")
    func aDoneTurnSubmitsNothingAtTheEnd() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        _ = session.handle(.classified(reading("open Safari", action: safari)))

        let closing = session.handle(.speechEnded)
        #expect(submitted(in: closing) == nil, "the app was opened, then asked for again")
        #expect(session.phase == .listening)
    }

    /// And the other half: if more was said than the part that was carried out, the
    /// whole turn still goes to the agent.
    @Test("A turn with more in it than was carried out still goes to the agent")
    func aCompoundTurnStillSubmits() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        _ = session.handle(.classified(reading("open Safari", action: safari)))
        _ = session.handle(.transcript("and go to GitHub", isFinal: true))
        // The finished sentence is beyond a closed choice, so it reads as work for the
        // model — and the agent is given all of it.
        _ = session.handle(.classified(
            reading("open Safari and go to GitHub", action: .model)
        ))
        let closing = session.handle(.speechEnded)
        #expect(submitted(in: closing)?.text == "open Safari and go to GitHub")
        #expect(submitted(in: closing)?.opening.isEmpty == true)
    }

    // MARK: - Nothing outlives its turn

    /// A record that outlived its turn is the defect this file keeps finding. Somebody
    /// who repeats themselves — which is what people do when they think they were
    /// ignored — must not be met with silence because the last turn did it.
    @Test("The same instruction in the next turn is carried out again")
    func performedIsForgottenWithTheTurn() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        _ = session.handle(.classified(reading("open Safari", action: safari)))
        _ = session.handle(.speechEnded)

        // A new turn, saying the same thing.
        _ = session.handle(.transcript("open Safari", isFinal: true))
        #expect(submitted(in: session.handle(
            .classified(reading("open Safari", action: safari))
        ))?.opening == [safari], "a repeated instruction was silently ignored")
    }

    /// The gate takes the floor mid-sentence — it fires during a run, which is exactly
    /// when somebody may be starting the next instruction — and it takes the turn with
    /// it. Note the turn is still open at this point: a fast action deliberately does
    /// not end one, so the speaker may still be talking when the gate interrupts.
    @Test("A question from the gate forgets what the turn before it did")
    func theGateForgetsThePerformedRecord() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        _ = session.handle(.classified(reading("open Safari", action: safari)))

        _ = session.handle(.agentAwaitingApproval("Delete 12 files?"))
        _ = session.handle(.transcript("yes", isFinal: true))

        _ = session.handle(.transcript("open Safari", isFinal: true))
        #expect(submitted(in: session.handle(
            .classified(reading("open Safari", action: safari))
        ))?.opening == [safari], "an instruction was ignored because a previous turn did it")
    }

    /// Ending the session and starting another must not carry anything across either.
    @Test("Stopping the session forgets what it did")
    func stoppingForgetsThePerformedRecord() {
        var session = listening()
        _ = session.handle(.transcript("open Safari", isFinal: true))
        _ = session.handle(.classified(reading("open Safari", action: safari)))
        _ = session.handle(.stop)
        _ = session.handle(.start)

        _ = session.handle(.transcript("open Safari", isFinal: true))
        #expect(submitted(in: session.handle(
            .classified(reading("open Safari", action: safari))
        ))?.opening == [safari])
    }

    // MARK: - Turning an action into something the loop will run

    @Test("An action becomes a call the agent loop can execute")
    func actionsBecomeOpeningMoves() {
        let move = safari.openingMove
        #expect(move?.tool == "activate_app")
        #expect(move?.input["bundle_identifier"]?.stringValue == "com.apple.Safari")
        #expect(move?.concludesTask == true)
    }

    /// A pre-decided move that no tool answers would be counted, recorded, and
    /// invisible.
    @Test("Doing nothing and asking the model become no call at all")
    func nonActionsBecomeNoMove() {
        #expect(FastPath.Action.none.openingMove == nil)
        #expect(FastPath.Action.model.openingMove == nil)
    }

    // MARK: - Winning the race against the endpointer

    /// `classifyNow()` fires the instant a final segment settles, and a real endpointer
    /// routinely says the turn is over a breath later — so for a short instruction the
    /// request and `speechEnded` are started together, and the request had no way to win
    /// a race it was never given the length of. This is the repair: a reading already
    /// outstanding for the exact text about to be flushed gets `fastPathGrace` before the
    /// turn goes the ordinary way.
    @Test("A pending reading holds the flush open rather than losing to the endpointer")
    func speechEndedWaitsOnAReadingAlreadyInFlight() {
        var session = listening(hasFastPath: true)
        // The final segment landing is what fires `classifyNow()` — see `asked(in:)`.
        let settled = session.handle(.transcript("open Safari", isFinal: true))
        #expect(!asked(in: settled).isEmpty, "the setup for this test asked nothing")

        // The endpointer, arriving before the answer to that request does.
        #expect(session.handle(.speechEnded) == [.armEndOfTurn(after: VoiceSession.fastPathGrace)],
                "the turn was flushed to the model before its own fast-path reading could land")
    }

    /// Nothing is ever outstanding for a session with no classifier configured, and
    /// `pendingClassification` would otherwise stay however it was last left — so the
    /// capability itself is what a session with no Jev key checks, not merely whether a
    /// request happens to have been asked.
    @Test("Without a classifier configured, speechEnded flushes exactly as before")
    func speechEndedIgnoresAPendingReadingWithoutFastPath() {
        var session = listening(hasFastPath: false)
        _ = session.handle(.transcript("open Safari", isFinal: true))

        let closing = session.handle(.speechEnded)
        #expect(closing.contains(.disarmEndOfTurn))
        #expect(submitted(in: closing) != nil, "a session with no classifier waited on one anyway")
    }

    /// The grace window is not another chance to act twice: if the reading lands and is
    /// carried out while `speechEnded` is waiting, the turn it eventually flushes must
    /// not submit what `perform` already did.
    @Test("A reading that lands inside the grace window is not submitted again when it ends")
    func aReadingThatLandsInTheGraceWindowIsNotResubmitted() {
        var session = listening(hasFastPath: true)
        _ = session.handle(.transcript("open Safari", isFinal: true))
        #expect(session.handle(.speechEnded) == [.armEndOfTurn(after: VoiceSession.fastPathGrace)])

        // The answer arrives, carries out the action, and takes no opener with it.
        let acted = session.handle(.classified(reading("open Safari", action: safari)))
        #expect(submitted(in: acted)?.opening == [safari])

        // The grace timer expiring is `.endOfTurn`, exactly as a settle timer would be.
        let closing = session.handle(.endOfTurn)
        #expect(submitted(in: closing) == nil, "the app was opened, then asked for again")
        #expect(session.phase == .listening)
    }

    /// The other half: a reading that resolves to nothing actionable inside the window
    /// must still fall through to the ordinary route once the window closes — waiting on
    /// a fast path costs nothing, but it must never cost the turn itself.
    @Test("A reading that names no action still reaches the model once the window closes")
    func aNonActionableReadingStillFallsThroughToTheModel() {
        var session = listening(hasFastPath: true)
        _ = session.handle(.transcript("what time is it", isFinal: true))
        #expect(session.handle(.speechEnded) == [.armEndOfTurn(after: VoiceSession.fastPathGrace)])

        _ = session.handle(.classified(
            reading("what time is it", action: .model)
        ))

        let closing = session.handle(.endOfTurn)
        #expect(submitted(in: closing)?.text == "what time is it")
        #expect(submitted(in: closing)?.opening.isEmpty == true)
    }
}
