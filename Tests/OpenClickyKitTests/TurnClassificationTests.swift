import Testing
import Foundation
@testable import OpenClickyKit

/// The rules that decide whether a classifier's opinion is allowed to change anything.
///
/// Almost every test here is about a *limit*. The reading can make the session wait
/// longer, stop sooner, or decline to act — and the suite's job is to hold the line
/// that it can never do the opposite, and that a session with no classifier, a slow
/// one, or one answering about the wrong sentence behaves exactly as it did before any
/// of this was written.
@Suite("Turn classification")
struct TurnClassificationTests {

    private func listening() -> VoiceSession {
        var session = VoiceSession(hasEchoCancellation: true)
        _ = session.handle(.start)
        return session
    }

    private func submitted(in effects: [VoiceSession.Effect]) -> String? {
        for effect in effects {
            if case let .submit(task) = effect { return task.text }
        }
        return nil
    }

    private func overheard(in effects: [VoiceSession.Effect]) -> String? {
        for effect in effects {
            if case let .overheard(text) = effect { return text }
        }
        return nil
    }

    private func asked(in effects: [VoiceSession.Effect]) -> TurnContext? {
        for effect in effects {
            if case let .classify(context) = effect { return context }
        }
        return nil
    }

    /// A reading, with everything neutral but the field under test.
    private func reading(
        _ utterance: String,
        addressed: Double = 0.99, complete: Double = 0.99, halt: Double = 0.01,
        intent: TurnReading.Intent = .instruction
    ) -> TurnReading {
        TurnReading(
            utterance: utterance, addressed: addressed, complete: complete,
            halt: halt, intent: intent, intentConfidence: 0.9
        )
    }

    // MARK: - The reading has to be about this sentence

    /// The failure this suite exists to prevent. Classification runs while the speaker
    /// is still going, so a reading routinely describes a *prefix* — and "delete the"
    /// is plainly unfinished where "delete the old screenshots" is not. Deciding the
    /// second with the first's answer would be confident and about a sentence nobody
    /// said.
    @Test("A reading about a shorter prefix never decides the finished sentence")
    func aStalePrefixDecidesNothing() {
        var session = listening()
        _ = session.handle(.transcript("open the", isFinal: true))
        _ = session.handle(.classified(reading("open the", addressed: 0.01)))
        // The sentence grew. The reading now describes something nobody is asking about.
        _ = session.handle(.transcript("settings app", isFinal: true))

        let closing = session.handle(.speechEnded)
        #expect(submitted(in: closing) == "open the settings app",
                "a reading of half the sentence suppressed the whole of it")
        #expect(overheard(in: closing) == nil)
    }

    @Test("A session with no reading at all behaves exactly as it did before")
    func noReadingChangesNothing() {
        var session = listening()
        _ = session.handle(.transcript("open the settings app", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "open the settings app")
    }

    // MARK: - Addressivity

    @Test("A turn confidently meant for somebody else is shown rather than run")
    func anOverheardTurnIsNotSubmitted() {
        var session = listening()
        _ = session.handle(.transcript("did you see the game last night", isFinal: true))
        _ = session.handle(.classified(reading(
            "did you see the game last night", addressed: 0.02, intent: .chitchat
        )))

        let closing = session.handle(.speechEnded)
        #expect(submitted(in: closing) == nil, "a remark to a colleague ran as a task")
        #expect(overheard(in: closing) == "did you see the game last night",
                "the words were dropped instead of shown")
        // And the session is ready for the next thing, carrying none of it forward.
        #expect(session.phase == .listening)
        #expect(session.heard.isEmpty)
    }

    /// The asymmetry that makes the gate safe. Acting on somebody else's sentence runs
    /// a task on the user's Mac; declining to act on one that was meant for the agent
    /// is a turn they have to repeat. Only the first is silent, so only near-certainty
    /// suppresses and the whole wide middle submits.
    @Test("An unsure reading submits, exactly as an absent one would", arguments: [
        0.16, 0.3, 0.5, 0.7,
    ])
    func onlyNearCertaintySuppresses(addressed: Double) {
        var session = listening()
        _ = session.handle(.transcript("open the settings app", isFinal: true))
        _ = session.handle(.classified(reading("open the settings app", addressed: addressed)))
        #expect(submitted(in: session.handle(.speechEnded)) == "open the settings app",
                "a turn was withheld on a judgement that was not confident")
    }

    // MARK: - Halting

    /// `VoiceCommand`'s set is the floor and stays authoritative. A model that thought
    /// "stop" was an instruction must not be able to turn a halt into a task — which is
    /// the exact failure that made people quit the app from the Dock.
    @Test("The word list still halts when the reading disagrees")
    func theWordListRemainsTheFloor() {
        var session = listening()
        _ = session.handle(.transcript("stop", isFinal: true))
        _ = session.handle(.classified(reading("stop", halt: 0.0, intent: .instruction)))

        let closing = session.handle(.speechEnded)
        #expect(closing.contains(.cancelRun), "a halt was submitted as a task")
        #expect(submitted(in: closing) == nil)
    }

    /// And the widening the set could never do on its own: it matches whole phrases,
    /// so everything around a halt defeats it.
    @Test("A halt the word list cannot match is still caught")
    func theReadingWidensTheHalt() {
        var session = listening()
        _ = session.handle(.transcript("no no that is not what I wanted stop", isFinal: true))
        _ = session.handle(.classified(reading(
            "no no that is not what I wanted stop", halt: 0.97, intent: .halt
        )))

        let closing = session.handle(.speechEnded)
        #expect(closing.contains(.cancelRun))
        #expect(submitted(in: closing) == nil)
    }

    /// "Stop the music" is an instruction about iTunes and has to reach the agent
    /// intact. A high-ish halt probability that is not near-certain must not eat it.
    @Test("An instruction that merely contains a halt word still runs")
    func aHaltWordInsideAnInstructionIsNotAHalt() {
        var session = listening()
        _ = session.handle(.transcript("stop the music", isFinal: true))
        _ = session.handle(.classified(reading("stop the music", halt: 0.4)))
        #expect(submitted(in: session.handle(.speechEnded)) == "stop the music")
    }

    // MARK: - Turn completion

    /// The judgement `VoiceTurn`'s word list cannot make: its own comment records that
    /// auxiliaries had to be removed because "what voices does Siri have" is a complete
    /// question ending on one. A reading has the evidence the list does not.
    @Test("A reading holds a turn the word list would have submitted")
    func theReadingCanHoldAnUnfinishedTurn() {
        var session = listening()
        _ = session.handle(.transcript("open the settings app and then", isFinal: true))
        _ = session.handle(.classified(reading(
            "open the settings app and then", complete: 0.05
        )))
        #expect(session.handle(.speechEnded) == [.armEndOfTurn(after: VoiceSession.grace)],
                "half a sentence went out as a whole instruction")
    }

    /// And the mirror: a complete question the word list would have held, because it
    /// ends on a word that usually dangles.
    @Test("A reading releases a turn the word list would have held")
    func theReadingCanReleaseAHeldTurn() {
        var session = listening()
        _ = session.handle(.transcript("tell me what it does with", isFinal: true))
        _ = session.handle(.classified(reading("tell me what it does with", complete: 0.95)))
        #expect(submitted(in: session.handle(.speechEnded)) == "tell me what it does with")
    }

    /// The grace is a wait, never a veto — the rule holds whoever asked for it.
    @Test("A turn held by a reading is still submitted when the grace expires")
    func aHeldTurnIsStillNeverLost() {
        var session = listening()
        _ = session.handle(.transcript("open the settings app and then", isFinal: true))
        _ = session.handle(.classified(reading(
            "open the settings app and then", complete: 0.01
        )))
        _ = session.handle(.speechEnded)
        #expect(submitted(in: session.handle(.endOfTurn)) == "open the settings app and then",
                "a reading withheld a turn twice, which is forever")
    }

    // MARK: - Asking

    @Test("A settled segment asks for a reading of the turn so far")
    func aPauseAsksForAReading() {
        var session = listening()
        _ = session.handle(.speechDetected)
        let asked = asked(in: session.handle(.transcript("can you check", isFinal: true)))
        #expect(asked?.utterance == "can you check")
        #expect(asked?.isRunInFlight == false)
    }

    /// There is nothing to read in silence, and a request per pause in a quiet room is
    /// a bill for nothing.
    @Test("Silence is never sent to be classified", arguments: ["", "   ", "\n"])
    func silenceIsNeverClassified(text: String) {
        var session = listening()
        #expect(asked(in: session.handle(.transcript(text, isFinal: true))) == nil)
    }

    /// What makes an answer legible as an answer. "Yes" is a reply if something asked
    /// and a stray noise if nothing did, and the words alone cannot tell which.
    @Test("The classifier is told what the agent last said")
    func theQuestionTravelsWithTheTurn() {
        var session = listening()
        _ = session.handle(.agentStartedWorking)
        _ = session.handle(.agentAwaitingApproval("Delete 12 files?"))
        _ = session.handle(.transcript("go ahead", isFinal: true))
        // The approval branch answers the gate rather than accumulating a turn, so the
        // question is checked where it is stored: on the next turn that asks.
        _ = session.handle(.transcript("and empty the trash", isFinal: true))
        #expect(asked(in: session.handle(.transcript("too", isFinal: true)))?.agentLastSaid
                == "Delete 12 files?")
    }

    /// A reading is an opinion about a turn, and barge-in ends the turn it was about.
    ///
    /// The setup is the ordinary one, not a contrived one: a reading is asked for at a
    /// pause and can easily land *after* the turn went out and the run started. If it
    /// survived into the next turn, someone repeating themselves word for word — which
    /// is exactly what people do when they think they were ignored — would be
    /// suppressed by a verdict about the sentence before.
    @Test("Noise that interrupts a run discards the reading of the turn before it")
    func detectionClearsTheReading() {
        var session = listening()
        _ = session.handle(.agentStartedWorking)
        _ = session.handle(.classified(reading("open the settings app", addressed: 0.01)))
        _ = session.handle(.speechDetected)
        _ = session.handle(.transcript("open the settings app", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "open the settings app",
                "a verdict about the previous turn suppressed this one")
    }

    /// The same rule down the other route into a new turn — the one taken when the
    /// vendor emits words before its detector settles.
    @Test("Words that interrupt a run discard the reading of the turn before it")
    func wordsClearTheReading() {
        var session = listening()
        _ = session.handle(.agentStartedWorking)
        _ = session.handle(.classified(reading("open the settings app", addressed: 0.01)))
        _ = session.handle(.transcript("open the settings app", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "open the settings app")
    }

    /// The gate takes the floor mid-sentence, and it takes the turn with it.
    @Test("A question from the gate discards the reading of the turn it interrupted")
    func theGateClearsTheReading() {
        var session = listening()
        _ = session.handle(.transcript("open the settings app", isFinal: true))
        _ = session.handle(.classified(reading("open the settings app", addressed: 0.01)))
        _ = session.handle(.agentAwaitingApproval("Delete 12 files?"))
        _ = session.handle(.transcript("yes", isFinal: true))
        // Back to work, and the next turn says what the abandoned one did.
        _ = session.handle(.transcript("open the settings app", isFinal: true))
        #expect(submitted(in: session.handle(.speechEnded)) == "open the settings app")
    }

    @Test("A reading that arrives after the session stopped changes nothing")
    func aReadingAfterTheEndIsIgnored() {
        var session = VoiceSession(hasEchoCancellation: true)
        #expect(session.handle(.classified(reading("anything", addressed: 0.0))) == [])
        #expect(session.phase == .idle)
    }

    // MARK: - The thresholds themselves

    @Test("A reading only speaks about the text it was asked about")
    func appliesIsExact() {
        let read = reading("open the settings app")
        #expect(read.applies(to: "open the settings app"))
        #expect(!read.applies(to: "open the settings"))
        #expect(!read.applies(to: "Open the settings app"))
    }

    /// The thresholds are asymmetric on purpose, and the direction is the safety
    /// argument. Pinned so that widening one is a deliberate edit rather than a drift.
    @Test("Suppressing needs more confidence than waiting does")
    func thresholdsLeanTowardsActing() {
        #expect(TurnReading.addressedFloor < TurnReading.completeFloor,
                "the judgement that can refuse a turn became the looser of the two")
        #expect(TurnReading.haltCeiling > 0.5, "a halt became easier to infer than not")
    }
}
